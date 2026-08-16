import Combine
import CoreLocation
import Foundation
import LongdoMapFramework
import MapConductorCore
import SwiftUI
import UIKit

/// SwiftUI を通さないホストからも Longdo の地図を使うための入口。
///
/// `LongdoMapView` の `Coordinator` をそのまま切り出したもの。SwiftUI の
/// `UIViewRepresentable` は薄いラッパーになり、React Native の
/// `reactnative-for-longdo` はこのクラスを直接使う。
/// `MapLibreMapHost` / `HereMapHost` / `GoogleMapHost` と同じ位置づけ。
///
/// `@_spi(MapConductorDriver)` なのでアプリ向けの凍結 API には載らない
/// （`scripts/api-surface.sh` が見る `.swiftinterface` に SPI は出ない）。
@_spi(MapConductorDriver)
@MainActor
public final class LongdoMapHost: MapViewCoordinatorBase<LongdoViewState>, LongdoBridge, UIGestureRecognizerDelegate {
    private var map: LongdoMap?
    private var controller: LongdoViewController?

    /// android-sdk の `cameraRestriction?.let { controller.setCameraRestriction(it) }` 相当。
    public func applyCameraRestriction(_ restriction: CameraRestriction?) {
        applyCameraRestriction(restriction, to: controller)
    }
    private var overlayScope: MapOverlayScope?

    /// マーカークラスタリング等のプラグインへ公開する描画 capability。
    /// android-for-longdo が `MarkerRenderingSupportKey` に登録するのと同じ役割。
    /// クラスタ側が算出したマーカーは `LongdoClusterMarkerRenderer` が集約し、
    /// `LongdoOverlayBinding` の DOM マーカー経路へ流す。
    private lazy var strategyManager: StrategyMarkerManager<LongdoActualMarker, LongdoClusterMarkerRenderer> = {
        let manager = StrategyMarkerManager<LongdoActualMarker, LongdoClusterMarkerRenderer>(
            makeRenderer: { [weak self] _ in
                LongdoClusterMarkerRenderer(onMarkersChanged: { [weak self] markers in
                    self?.overlayBinding?.setClusterMarkers(markers)
                })
            },
            shouldAddMarkers: { [weak self] in self?.didReady ?? false },
            currentCamera: { [weak self] in self?.lastOverlayCamera }
        )
        return manager
    }()

    /// クラスタ再計算に渡す直近のカメラ（可視領域つき）。
    private var lastOverlayCamera: MapCameraPosition?
    private var overlayBinding: LongdoOverlayBinding?
    private let moveDispatcher = LongdoCameraMoveDispatcher()
    /// カメラの読み取りが往復中かどうか。Longdo は同じ 1 フレームに対して `Drag` と
    /// `Location` の両方を出すことがあるため、重なった通知は 1 回にまとめる。
    private var cameraEmissionScheduled = false
    /// 読み取り中に来たイベント。往復が済んだらもう一度だけ読む。
    private var cameraEmissionPending = false
    /// True while ``emitCamera()`` is running. See the comment there: the SDK's synchronous
    /// bridge spins a nested run loop, so this method can re-enter itself.
    private var isEmittingCamera = false
    private var didReady = false
    private var lastUISettings = MapUISettings()
    private var infoBubbleCoordinator: InfoBubbleOverlayCoordinator?
    private var markerAnimationOverlay: MarkerAnimationOverlayCoordinator?
    /// Last tap observed at the UIKit level. The SDK's `LocationMode.Pointer` position is
    /// vertically biased on device (safe-area handling), so click handling prefers the
    /// native touch point unprojected through our own camera math.
    private var lastNativeTapPoint: CGPoint?
    private var lastNativeTapUptime: TimeInterval = 0
    private var markerDragRecognizer: UILongPressGestureRecognizer?
    /// Mirrors the WebView's one-finger pan onto the native overlay container. Longdo renders
    /// its map on WebKit's compositor, so changing individual bubble frames from bridge events
    /// can remain visually behind the map while a touch is down. A native transform stays in the
    /// same gesture transaction; the exact geographic layout is restored when the gesture ends.
    private var infoBubblePanRecognizer: UIPanGestureRecognizer?
    private var isMirroringInfoBubblePan = false

    func makeMap(apiKey explicit: String?) -> LongdoMap {
        // SwiftUI は同じ Coordinator に対して `makeUIView` を複数回呼ぶことがあり
        // （content が更新されるページで実際に 3 回呼ばれる）、そのたびに新しい
        // `LongdoMap` を作ると、ビュー階層に載っているのは最初の 1 個だけで
        // `self.map` は誰にも表示されない孤児を指すことになる。以降のブリッジ呼び出し
        // （`Overlays.add` / `bound` / `location`）はすべてその見えないマップへ向かい、
        // マーカーはレイアウトされていない 0×0 の WebView の DOM に追加されて
        // 画面に出ない。Coordinator 1 つにつきマップは 1 つとし、2 回目以降は
        // 生成済みのものを返す（破棄は `dismantleUIView` → `unbind()` で map = nil）。
        if let existing = map { return existing }
        let map = LongdoMap()
        self.map = map
        map.apiKey = LongdoInitSDK.resolveApiKey(explicit) ?? ""

        let option = LongdoMap.Option()
        option.layer = map.ldstatic("Layers", with: state.mapDesignType.layerName)
        option.location = state.cameraPosition.position.clLocation
        option.zoom = Int(LongdoViewController.coreZoomToLongdo(state.cameraPosition.zoom).rounded())
        option.zoomRange = 1...20
        option.onReady = { [weak self] in self?.handleReady() }
        map.options = option
        map.render()

        let typedHolder = LongdoMapViewHolder(map: map)
        let controller = LongdoViewController(holder: typedHolder, bridge: self)
        self.controller = controller
        state.setMapViewHolder(controller.typedHolder)

        // Observe taps at the UIKit level (non-consuming) so click handling can use the
        // exact touch position instead of the SDK's biased pointer location.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleNativeTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        map.addGestureRecognizer(tap)

        // Custom marker drag: a long-press over a draggable marker picks it up, the finger
        // moves it, releasing drops it (same approach as ios-for-arcgis). The SDK's own
        // marker dragging is never used — an interactive DOM marker would swallow touches
        // before they reach the map. While active this recognizer cancels the WebView's
        // touches so the map does not pan underneath the drag.
        let drag = UILongPressGestureRecognizer(target: self, action: #selector(handleMarkerDrag(_:)))
        drag.minimumPressDuration = 0.35
        drag.delegate = self
        map.addGestureRecognizer(drag)
        self.markerDragRecognizer = drag

        let bubblePan = UIPanGestureRecognizer(target: self, action: #selector(handleInfoBubblePan(_:)))
        bubblePan.maximumNumberOfTouches = 1
        bubblePan.cancelsTouchesInView = false
        bubblePan.delegate = self
        // A stationary long press over a draggable marker must win. On a regular map pan the
        // long-press recognizer fails as soon as the finger moves beyond its small tolerance;
        // `translation(in:)` then includes that initial movement, so the bubble does not drift.
        bubblePan.require(toFail: drag)
        map.addGestureRecognizer(bubblePan)
        self.infoBubblePanRecognizer = bubblePan

        let scope = MapOverlayScope()
        self.overlayScope = scope
        let binding = LongdoOverlayBinding(bridge: self, scope: scope, controller: controller)
        self.overlayBinding = binding
        binding.setMarkerProjector { [weak self] point in self?.projectToScreen(point) }

        // Info bubbles are SwiftUI views hosted in a passthrough container on top of the
        // WebView; geo→screen projection goes through the map's internal MapLibre renderer.
        attachInfoBubbleContainer(to: map)
        self.infoBubbleCoordinator = InfoBubbleOverlayCoordinator(
            container: infoBubbleContainer,
            project: { [weak self] point in self?.projectToScreen(point) },
            projectionGate: screenProjectionGate(feature: "InfoBubble"),
            resolveMarkerStateForIcon: { [weak binding] id, bubbleMarker in
                binding?.markerState(for: id) ?? bubbleMarker
            },
            iconMetrics: { markerState in
                let icon = (markerState.icon ?? DefaultMarkerIcon()).toBitmapIcon()
                return MarkerIconMetrics(size: icon.size, anchor: icon.anchor, infoAnchor: icon.infoAnchor)
            }
        )
        binding.setMarkerDragObserver { [weak self] id in
            self?.infoBubbleCoordinator?.updateInfoBubblePosition(for: id)
        }

        // Screen-space marker animation layer: shares the info-bubble
        // container (inserted below the bubbles) and the map projection.
        let animationOverlay = MarkerAnimationOverlayCoordinator(
            container: infoBubbleContainer,
            project: { [weak self] point in self?.projectToScreen(point) },
            projectionGate: screenProjectionGate(feature: "marker animation overlay")
        )
        self.markerAnimationOverlay = animationOverlay
        binding.setMarkerAnimationOverlay(animationOverlay)
        return map
    }

    /// Camera used for bubble projection, queried directly from the map and cached until the
    /// next camera event. The event-driven `state.cameraPosition` snapshot cannot be used:
    /// on device the event stream lags the rendered state, and the initial camera is applied
    /// with a rounded native zoom, so the snapshot can disagree with what is on screen
    /// (placing bubbles far off-screen). Asking the map itself keeps projection and
    /// rendering self-consistent.
    private var projectionCamera: (center: CLLocationCoordinate2D, zoom: Double, bearing: Double)?

    fileprivate func invalidateProjectionCamera() {
        projectionCamera = nil
    }

    private func currentProjectionCamera() -> (center: CLLocationCoordinate2D, zoom: Double, bearing: Double)? {
        if let projectionCamera { return projectionCamera }
        guard let map,
              let center = map.call(method: "location", args: nil) as? CLLocationCoordinate2D,
              let longdoZoom = Self.doubleValue(map.call(method: "zoom", args: nil)) else { return nil }
        let bearing = Self.doubleValue(map.call(method: "rotate", args: nil)) ?? 0
        let camera = (center, LongdoViewController.longdoZoomToCore(longdoZoom), bearing)
        projectionCamera = camera
        return camera
    }

    /// Projects a geographic point to view coordinates mathematically (Web Mercator around
    /// the current camera). The bridge's `Renderer.project` cannot be used: the SDK mangles
    /// the arguments/return value and always yields (0,0). The camera zoom is Google-parity
    /// (256·2^zoom pt world width), so this matches the WebView's rendering; tilt is not
    /// modeled (the tilted-map case is approximate).
    ///
    /// **投影を持つのはこのホストであって、ホルダーではない。**
    /// `LongdoMapViewHolder.toScreenOffset` は WebView ブリッジに同期 API が無いため
    /// nil を返すが、投影自体はここのカメラ計算で成立している。InfoBubble も
    /// マーカー追従もこの経路で動く（だから `screenProjectionSync` は
    /// unsupported ではなく degraded と宣言している）。
    /// SwiftUI を通さないホスト（React Native）も**ここを呼ぶこと**。
    /// 各ホストが投影を書き直すと、片方だけ直る／片方だけずれる。
    public func toScreenOffset(_ point: GeoPointProtocol) -> CGPoint? {
        projectToScreen(point)
    }

    /// ``toScreenOffset(_:)`` の逆。スクリーン座標 → 地理座標。
    /// タップの当たり判定はこれを通す。**SDK 側のタッチ判定は使わない**
    /// （`LocationMode.Pointer` は実機で縦方向にずれる。`handlePointerClick` のコメント参照）。
    public func fromScreenOffset(_ point: CGPoint) -> GeoPoint? {
        unprojectFromScreen(point)
    }

    /// 式はコアの ``WebMercatorScreenProjection``。ここはカメラとビューの大きさを
    /// 渡すだけにすること（android-sdk-core の同名クラスと同じ式）。
    /// 式を各プロバイダへ写すと、片方だけ直る／片方だけずれる。
    private func projectToScreen(_ point: GeoPointProtocol) -> CGPoint? {
        guard let camera = projectionCameraPosition(), let map else { return nil }
        return WebMercatorScreenProjection.toScreenOffset(point, camera: camera, size: map.bounds.size)
    }

    /// Inverse of ``projectToScreen(_:)``: view coordinates → geographic point.
    private func unprojectFromScreen(_ point: CGPoint) -> GeoPoint? {
        guard let camera = projectionCameraPosition(), let map else { return nil }
        return WebMercatorScreenProjection.fromScreenOffset(point, camera: camera, size: map.bounds.size)
    }

    /// 投影に使うカメラ。地図が描ける状態になるまでは投影しない
    /// （まだレイアウトも座標も定まっていない）。
    private func projectionCameraPosition() -> MapCameraPosition? {
        guard didReady, let camera = currentProjectionCamera() else { return nil }
        return MapCameraPosition(
            position: GeoPoint(latitude: camera.center.latitude, longitude: camera.center.longitude, altitude: 0),
            zoom: camera.zoom,
            bearing: camera.bearing,
            tilt: 0
        )
    }

    /// 地図を作り、制限とコンテンツまで流して返す。
    ///
    /// SwiftUI の `makeUIView` が踏んでいた手順をそのまま公開したもの。
    /// React Native のような非 SwiftUI ホストも同じ入口を通る
    /// （`MapLibreMapHost.makeMapView` と同じ位置づけ）。
    public func makeMapView(
        apiKey: String?,
        cameraRestriction: CameraRestriction?,
        content: MapViewContent
    ) -> LongdoMap {
        if let sdkInitialize = handlers.sdkInitialize {
            Self.runOnce(sdkInitialize)
        }
        let map = makeMap(apiKey: apiKey)
        applyCameraRestriction(cameraRestriction)
        updateContent(content)
        return map
    }

    public func updateContent(_ content: MapViewContent) {
        overlayBinding?.sync(content)
        infoBubbleCoordinator?.syncInfoBubbles(content.infoBubbles)
        infoBubbleCoordinator?.updateAllLayouts()
    }

    public func unbind() {
        // 登録した capability を取り下げる。レジストリの持ち主は state で、ビューより長生きするため、
        // ここで外さないと破棄済みのコントローラを掴んだまま残る。
        state.serviceRegistry.removeProviderRegistrations()
        cameraEmissionScheduled = false
        cameraEmissionPending = false
        isMirroringInfoBubblePan = false
        infoBubbleContainer.transform = .identity
        if let infoBubblePanRecognizer {
            map?.removeGestureRecognizer(infoBubblePanRecognizer)
        }
        infoBubblePanRecognizer = nil
        moveDispatcher.cancel()
        markerAnimationOverlay?.unbind()
        markerAnimationOverlay = nil
        overlayBinding?.setMarkerAnimationOverlay(nil)
        infoBubbleCoordinator?.unbind()
        infoBubbleCoordinator = nil
        infoBubbleContainer.removeFromSuperview()
        // クラスタ用レンダラ／コントローラも破棄する。
        strategyManager.clear()
        overlayBinding?.setClusterMarkers(nil)
        overlayBinding?.unbind()
        overlayBinding = nil
        overlayScope?.clear()
        overlayScope = nil
        // 登録済みオーバーレイコントローラ（拡張モジュール含む）を破棄する。
        controller?.destroy()
        state.setController(nil)
        state.setMapViewHolder(nil)
        controller = nil
        map = nil
    }

    // MARK: - LongdoBridge

    func ldobject(_ type: String, with args: [Any]) -> LongdoMap.LDObject {
        map!.ldobject(type, with: args)
    }

    func ldstatic(_ type: String, with name: String) -> LongdoMap.LDStatic {
        map!.ldstatic(type, with: name)
    }

    @discardableResult
    func call(_ method: String, args: [Any]?) -> Any? {
        map?.call(method: method, args: args)
    }

    @discardableResult
    func objectCall(_ object: LongdoMap.LDObject, method: String, args: [Any]?) -> Any? {
        map?.objectCall(ldobject: object, method: method, args: args)
    }

    func runJavaScript(_ js: String) {
        map?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Ready / events

    /// Longdo runs inside a web view, so gestures are toggled through its JS
    /// API rather than a native property. Applied on every update and re-applied
    /// once the page reports ready, since calls before that are dropped.
    /// Longdo's JS API only gates *mouse* input (`map.Ui.Mouse`), so these flags
    /// take effect with a trackpad or mouse but not for touch drags:
    /// `map.rotate()` / `map.pitch()` set the camera angle rather than gating a
    /// gesture, and native touch interception was tried and does not win against
    /// the web view's own handling. Touch gating is therefore unsupported here.
    public func updateGestures(_ ui: MapUISettings) {
        lastUISettings = ui
        MapUISettingsDiagnostics.warnIfRequested(
            ui.rotateGesture,
            gesture: .rotate,
            provider: "Longdo",
            reason: "the Longdo JS API has no rotation gesture toggle (map.rotate only sets the angle)"
        )
        MapUISettingsDiagnostics.warnIfRequested(
            ui.tiltGesture,
            gesture: .tilt,
            provider: "Longdo",
            reason: "the Longdo JS API has no tilt gesture toggle (map.pitch only sets the angle)"
        )
        guard didReady else { return }
        let js = """
        (function(){
          try {
            var m = window.map;
            if (!m || !m.Ui || !m.Ui.Mouse) return;
            m.Ui.Mouse.enableDrag(\(ui.scrollGesture));
            m.Ui.Mouse.enableWheel(\(ui.zoomGesture));
          } catch (e) {}
        })()
        """
        map?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func handleReady() {
        guard !didReady else { return }
        didReady = true
        controller?.onMapReady()
        state.setController(controller)
        // Publish marker rendering as a map-scoped capability. Add-on modules resolve it
        // from the registry; this provider never learns that clustering exists.
        state.serviceRegistry.put(MarkerRenderingSupportKey.self, strategyManager)
        // 拡張モジュール（ヒートマップ等）がオーバーレイコントローラを登録できるようにする。
        // clear() の後に置くこと（先に置くと直後の clear() で消える）。
        if let controller {
            state.serviceRegistry.put(OverlayControllerRegistryKey.self, controller.overlayControllers)
        }
        // ホルダーは同期の座標変換を持たない（WebView ブリッジ越しのため nil を返す）。
        // ただしオーバーレイの配置は JS 側の独自経路で行っており、InfoBubble も
        // マーカーも実際に動く。
        //
        // よって Unsupported ではなく Degraded。Unsupported にすると
        // ScreenProjectionRequirement がスクリーン空間の機能を落としてしまい、
        // 動いているものを止めることになる。android-for-longdo と同じ判断。
        state.serviceRegistry.declare(
            .screenProjectionSync,
            .degraded(
                "the holder API has no synchronous conversion; overlays are placed "
                    + "through the Longdo JS bridge instead"
            )
        )
        // タイル方式のマーカーの当たり判定は「いまのカメラ」を要る
        // （`LongdoOverlayBinding.handleMarkerTap` がズームからタイルを引くため）。
        // カメラ**イベント**が来るまで nil のままだと、地図を一度も動かさないうちは
        // タイル上のマーカーをタップしても黙って落ちる（実機で確認した症状）。
        // ready の時点で地図に直接聞いて種を入れる。イベントは配らない。
        if let camera = readNativeCamera() {
            lastOverlayCamera = camera
            overlayBinding?.setCurrentCamera(camera)
        }
        strategyManager.flush()
        // Longdo のコントローラはマップ準備完了後に有効になるため、それまでに要求された
        // cameraRestriction をここで適用する。
        reapplyCameraRestriction(to: controller)
        // Disable Longdo's own long-press popup (context menu, DOM class
        // .ldmap-contextmenu): long-pressing a marker or the map would otherwise show the
        // SDK's coordinate balloon. The bridge call Ui.ContextMenu.visible(false) has no
        // effect in SDK 4.1.4, so turn it off inside the page — via the JS API when
        // available, with a CSS kill switch as a version-tolerant fallback.
        let disableContextMenu = """
        (function(){
          try { if (window.map && map.Ui && map.Ui.ContextMenu && map.Ui.ContextMenu.visible) map.Ui.ContextMenu.visible(false); } catch (e) {}
          var style = document.createElement('style');
          style.textContent = '.ldmap-contextmenu{display:none !important;}';
          document.head.appendChild(style);
        })()
        """
        map?.evaluateJavaScript(disableContextMenu, completionHandler: nil)
        updateGestures(lastUISettings)
        bindEvents()
        overlayBinding?.markReady()
        controller?.notifyMapInitialized()
        onMapLoaded?(state)
        // Bubbles synced before ready were laid out while projection was unavailable
        // (hidden); re-run the layout now that the camera can be queried. Extra delayed
        // passes cover slower devices where the map settles after the ready callback.
        for delay in [0.0, 0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.invalidateProjectionCamera()
                self?.infoBubbleCoordinator?.updateAllLayouts()
            }
        }
    }

    private func bindEvents() {
        guard let map else { return }
        let camera: () -> Void = { [weak self] in self?.scheduleCameraEmission() }
        for name in ["Location", "Zoom", "Rotate", "Pitch"] {
            map.call(method: "Event.bind", args: [map.ldstatic("EventName", with: name), camera])
        }
        // `Location` remains the canonical camera-change event. Also subscribe to Longdo's
        // documented in-progress pan event (`Drag`) and finger-release event (`Drop`) so touch
        // panning explicitly feeds the same camera path. `Drag` carries a delta payload while
        // `Drop` has no payload. The dispatcher deliberately still ends on a quiet period rather
        // than on Drop, because momentum can continue after finger-up.
        let drag: (Any?) -> Void = { [weak self] _ in self?.scheduleCameraEmission() }
        map.call(method: "Event.bind", args: [map.ldstatic("EventName", with: "Drag"), drag])
        map.call(method: "Event.bind", args: [map.ldstatic("EventName", with: "Drop"), camera])
        bindRendererClick(map)
        for name in ["OverlayClick", "OverlayDrop", "OverlayDrag"] {
            let event = name
            map.call(method: "Event.bind", args: [map.ldstatic("EventName", with: name), { [weak self] (result: Any?) in
                self?.overlayBinding?.handleOverlayEvent(event: event, result: result)
            }])
        }
    }

    /// Longdo consumes its public `Click` event when one of its polygon overlays is under the
    /// pointer. `Renderer` is the underlying MapLibre map and receives the click regardless.
    ///
    /// LongdoMapFramework only exposes native callbacks through `Event.bind`. Bind a private
    /// event name to obtain one of those callbacks, then have `Renderer.on("click")` invoke the
    /// framework's generated bridge function with the MapLibre coordinate. If Renderer is not
    /// available (older framework), retain the public Longdo Click path as a compatibility
    /// fallback. Exactly one path is installed, so the shared click cascade cannot run twice.
    private func bindRendererClick(_ map: LongdoMap) {
        let bridgeEvent = "__MapConductorRendererClick"
        let rendererClick: (Any?) -> Void = { [weak self] result in self?.handleClick(result) }
        map.call(method: "Event.bind", args: [bridgeEvent, rendererClick])

        let script = """
        (function(){
          try {
            var m = (typeof objectList !== 'undefined') ? objectList[0] : null;
            var r = m ? m.Renderer : null;
            var callbacks = (typeof bindFunc !== 'undefined') ? bindFunc['\(bridgeEvent)'] : null;
            if (!m || !r || typeof r.on !== 'function' || !callbacks || callbacks.length === 0) return false;
            if (m.__mcRendererClickBound) return true;
            m.__mcRendererClickBound = true;
            var notify = callbacks[callbacks.length - 1];
            r.on('click', function(event) {
              try {
                var p = event && event.lngLat;
                if ((!p || typeof p.lng !== 'number' || typeof p.lat !== 'number') &&
                    event && event.point && typeof r.unproject === 'function') {
                  p = r.unproject(event.point);
                }
                if (p && typeof p.lng === 'number' && typeof p.lat === 'number') {
                  notify({ lon: p.lng, lat: p.lat });
                }
              } catch (e) {}
            });
            return true;
          } catch (e) { return false; }
        })()
        """
        map.evaluateJavaScript(script) { [weak self, weak map] result, _ in
            guard (result as? Bool) != true, let self, let map else { return }
            let click: () -> Void = { [weak self] in self?.handlePointerClick() }
            map.call(method: "Event.bind", args: [map.ldstatic("EventName", with: "Click"), click])
        }
    }

    /// Asks the page for the camera and emits it once the answer arrives.
    ///
    /// **同期の `map.call` をここで使ってはいけない。** SDK の同期ブリッジは JS の応答を
    /// ネストしたランループで待つので、1 値につきメインスレッドが止まる。パン中は
    /// 毎フレーム来るため、5 値を 1 つずつ聞くと 1 秒のうち 800ms が停止時間になる
    /// （実機計測。todo/20260814.txt の 2026-08-15 追記）。
    ///
    /// 読み中に次のイベントが来たら「あとで 1 回」だけ覚えておく。往復の実力以上には
    /// 要求を積まない。
    private func scheduleCameraEmission() {
        guard !cameraEmissionScheduled else {
            cameraEmissionPending = true
            return
        }
        cameraEmissionScheduled = true
        readNativeCameraFromPage { [weak self] camera in
            guard let self else { return }
            self.cameraEmissionScheduled = false
            if let camera { self.emitCamera(camera) }
            if self.cameraEmissionPending {
                self.cameraEmissionPending = false
                self.scheduleCameraEmission()
            }
        }
    }

    /// Longdo JS API の `map.bound()`（引数なしで現在の表示範囲を返す）から可視領域を組み立てる。
    /// 四隅は Longdo が矩形しか返さないため nil（android-for-longdo も同じく bounds だけを渡す）。
    private static func visibleRegion(from map: LongdoMap) -> MapConductorCore.VisibleRegion? {
        guard let raw = map.call(method: "bound", args: nil) as? [String: Any] else { return nil }
        return visibleRegion(
            minLat: doubleValue(raw["minLat"]),
            maxLat: doubleValue(raw["maxLat"]),
            minLon: doubleValue(raw["minLon"]),
            maxLon: doubleValue(raw["maxLon"])
        )
    }

    /// 同期の `bound` からでも、ページ側でまとめて読んだ JSON からでも同じものを組む。
    private static func visibleRegion(
        minLat: Double?,
        maxLat: Double?,
        minLon: Double?,
        maxLon: Double?
    ) -> MapConductorCore.VisibleRegion? {
        guard let minLat, let maxLat, let minLon, let maxLon else { return nil }
        return MapConductorCore.VisibleRegion(
            bounds: GeoRectBounds(
                southWest: GeoPoint(latitude: minLat, longitude: minLon, altitude: 0),
                northEast: GeoPoint(latitude: maxLat, longitude: maxLon, altitude: 0)
            ),
            nearLeft: nil,
            nearRight: nil,
            farLeft: nil,
            farRight: nil
        )
    }

    /// ページ側でカメラ 5 値をまとめて 1 つの JSON にしてから受け取る。**往復は 1 回**。
    ///
    /// android-for-longdo の `bindingScript()` にある `emitCamera` と同じ形
    /// （あちらは `lon/lat/zoom/rotate/pitch/bounds` を 1 つの JSON にして push する）。
    /// iOS も同じ構造にする。SDK の同期 `call` を 1 値ずつ回すと往復の本数がそのまま
    /// メインスレッドの停止時間になり、パン中に追従が遅れる。
    ///
    /// 地図の実体はページのスクリプトスコープにある `objectList[0]`（window のグローバル
    /// ではない）。``LongdoMarkerTileRenderer`` が `objectList[0].Renderer` へ
    /// source/layer を注入しているのと同じ経路で、こちらは値を読むだけ。
    private func readNativeCameraFromPage(_ completion: @escaping (MapCameraPosition?) -> Void) {
        guard let map else {
            completion(nil)
            return
        }
        let js = """
        (function(){
          try {
            var m = (typeof objectList !== 'undefined') ? objectList[0] : null;
            if (!m) return null;
            var c = m.location();
            var b = null;
            try { b = m.bound(); } catch (e) {}
            return JSON.stringify({
              lat: c.lat, lon: c.lon,
              zoom: m.zoom(), rotate: m.rotate(), pitch: m.pitch(),
              minLat: b ? b.minLat : null, maxLat: b ? b.maxLat : null,
              minLon: b ? b.minLon : null, maxLon: b ? b.maxLon : null
            });
          } catch (e) { return null; }
        })()
        """
        map.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else {
                completion(nil)
                return
            }
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let lat = Self.doubleValue(raw["lat"]),
                  let lon = Self.doubleValue(raw["lon"]) else {
                completion(nil)
                return
            }
            completion(self.makeCamera(
                latitude: lat,
                longitude: lon,
                longdoZoom: Self.doubleValue(raw["zoom"]) ?? 0,
                rotate: Self.doubleValue(raw["rotate"]) ?? 0,
                pitch: Self.doubleValue(raw["pitch"]) ?? 0,
                visibleRegion: Self.visibleRegion(
                    minLat: Self.doubleValue(raw["minLat"]),
                    maxLat: Self.doubleValue(raw["maxLat"]),
                    minLon: Self.doubleValue(raw["minLon"]),
                    maxLon: Self.doubleValue(raw["maxLon"])
                )
            ))
        }
    }

    private func makeCamera(
        latitude: Double,
        longitude: Double,
        longdoZoom: Double,
        rotate: Double,
        pitch: Double,
        visibleRegion: MapConductorCore.VisibleRegion?
    ) -> MapCameraPosition {
        MapCameraPosition(
            position: GeoPoint(latitude: latitude, longitude: longitude, altitude: 0),
            zoom: LongdoViewController.longdoZoomToCore(longdoZoom),
            bearing: rotate,
            tilt: pitch,
            paddings: state.cameraPosition.paddings,
            // マーカークラスタリングは `visibleRegion.bounds` で表示範囲内のマーカーを
            // 絞り込むため、ここで付けないとクラスタが一切描画されない
            // （android-for-longdo も onCameraMove の bounds から同じものを組み立てている）。
            visibleRegion: visibleRegion
        )
    }

    /// 地図に直接いまのカメラを聞く（同期）。**イベント経路では使わないこと**
    /// （``readNativeCameraFromPage(_:)`` のコメント参照）。ready 直後の種入れのように
    /// 1 回だけ必要な場面のためにある。
    private func readNativeCamera() -> MapCameraPosition? {
        guard let map else { return nil }
        guard let loc = map.call(method: "location", args: nil) as? CLLocationCoordinate2D else { return nil }
        return makeCamera(
            latitude: loc.latitude,
            longitude: loc.longitude,
            longdoZoom: Self.doubleValue(map.call(method: "zoom", args: nil)) ?? 0,
            rotate: Self.doubleValue(map.call(method: "rotate", args: nil)) ?? 0,
            pitch: Self.doubleValue(map.call(method: "pitch", args: nil)) ?? 0,
            visibleRegion: Self.visibleRegion(from: map)
        )
    }

    private func emitCamera(_ updated: MapCameraPosition) {
        // この先で呼ぶカメラ制限の補正は同期 `map.call` を通る。SDK の同期ブリッジは
        // 応答を **ネストしたランループ**（`-[NSRunLoop runMode:beforeDate:]`）で待つため、
        // その間にメインキューへ積んだブロックが動き、ここへ再入し得る
        // （実機のクラッシュログのバックトレースで確認）。
        // 入れ子の回は捨て、外側が終わってから 1 回だけ出し直す。
        guard !isEmittingCamera else {
            scheduleCameraEmission()
            return
        }
        isEmittingCamera = true
        defer { isEmittingCamera = false }
        // 範囲・ズーム制限に違反していれば矩形内へ引き戻す。再適用で再度この経路を通り、
        // そこでは補正不要になり通常フローへ進む。android-sdk と同じく、補正した回は
        // state 更新もコールバックも行わない。
        if controller?.applyCameraRestrictionCorrectionIfNeeded(updated) == true { return }
        state.updateCameraPosition(updated)
        lastOverlayCamera = updated
        overlayBinding?.setCurrentCamera(updated)
        // クラスタは visibleRegion.bounds を使って再計算する。
        Task { [weak self] in await self?.strategyManager.onCameraChanged(updated) }
        // Bubbles must track the map on every camera event, including suppressed echoes. During
        // a touch pan their container follows the UIKit gesture directly; updating their absolute
        // frames at the same time would apply both the geographic movement and the translation.
        //
        // 投影には**いま読んだ値をそのまま使う**。`invalidateProjectionCamera()` して
        // `currentProjectionCamera()` に聞き直すと、同じ値を得るためだけに
        // location / zoom / rotate をブリッジ越しに 3 往復させることになる。Longdo の
        // 同期 `call` は応答をネストしたランループで待つので、往復はそのままメイン
        // スレッドの停止時間になる。
        projectionCamera = (
            CLLocationCoordinate2D(
                latitude: updated.position.latitude,
                longitude: updated.position.longitude
            ),
            updated.zoom,
            updated.bearing
        )
        if !isMirroringInfoBubblePan {
            infoBubbleCoordinator?.updateAllLayouts()
        }

        // Swallow the echo events Longdo emits for moves WE applied programmatically; only
        // genuine user-driven moves are dispatched. The controller decides by comparing the
        // event's camera against the last applied target (deterministic, no wall clock).
        if controller?.shouldSuppressCameraEcho(updated) == true { return }

        moveDispatcher.dispatch(
            position: updated,
            onStart: { [weak self] pos in self?.controller?.notifyCameraMoveStart(pos); self?.onCameraMoveStart?(pos) },
            onMove: { [weak self] pos in self?.controller?.notifyCameraMove(pos); self?.onCameraMove?(pos) },
            onEnd: { [weak self] pos in self?.controller?.notifyCameraMoveEnd(pos); self?.onCameraMoveEnd?(pos) }
        )
    }

    @objc private func handleNativeTap(_ recognizer: UITapGestureRecognizer) {
        lastNativeTapPoint = recognizer.location(in: recognizer.view)
        lastNativeTapUptime = ProcessInfo.processInfo.systemUptime
    }

    @objc private func handleMarkerDrag(_ recognizer: UILongPressGestureRecognizer) {
        guard let view = recognizer.view else { return }
        let point = recognizer.location(in: view)
        switch recognizer.state {
        case .began:
            if overlayBinding?.beginMarkerDrag(at: point) == true {
                // UIKit touch cancellation does not reliably stop the WebView's internal
                // MapLibre pan (nor its momentum), so freeze it for the drag's duration.
                _ = map?.call(method: "Renderer.dragPan.disable", args: nil)
            } else {
                // No draggable marker under the finger: cancel so the tap/click pipeline
                // and the map's own gestures are not disturbed.
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
        case .changed:
            if let position = unprojectFromScreen(point) {
                overlayBinding?.updateMarkerDrag(to: position)
            }
        case .ended:
            overlayBinding?.endMarkerDrag(at: unprojectFromScreen(point))
            _ = map?.call(method: "Renderer.dragPan.enable", args: nil)
        case .cancelled, .failed:
            overlayBinding?.endMarkerDrag(at: nil)
            _ = map?.call(method: "Renderer.dragPan.enable", args: nil)
        default:
            break
        }
    }

    @objc private func handleInfoBubblePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            isMirroringInfoBubblePan = true
            infoBubbleContainer.transform = .identity
        case .changed:
            guard isMirroringInfoBubblePan, let map else { return }
            let translation = recognizer.translation(in: map)
            infoBubbleContainer.transform = CGAffineTransform(
                translationX: translation.x,
                y: translation.y
            )
        case .ended, .cancelled, .failed:
            guard isMirroringInfoBubblePan else { return }
            isMirroringInfoBubblePan = false
            infoBubbleContainer.transform = .identity
            invalidateProjectionCamera()
            infoBubbleCoordinator?.updateAllLayouts()
        default:
            break
        }
    }

    public nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    public nonisolated func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        MainActor.assumeIsolated {
            let point = gestureRecognizer.location(in: gestureRecognizer.view)
            if gestureRecognizer === markerDragRecognizer {
                return overlayBinding?.hasDraggableMarker(at: point) == true
            }
            if gestureRecognizer === infoBubblePanRecognizer {
                // A drag beginning on interactive bubble content belongs to that content. Also
                // leave draggable markers to the long-press recognizer instead of moving both
                // the marker and every bubble container.
                let pointInContainer = infoBubbleContainer.convert(point, from: gestureRecognizer.view)
                if infoBubbleContainer.hitTest(pointInContainer, with: nil) != nil { return false }
                return overlayBinding?.hasDraggableMarker(at: point) != true
            }
            return true
        }
    }

    private func handlePointerClick() {
        guard let map else { return }
        // Prefer the UIKit touch position unprojected through our own camera math: the
        // SDK's Pointer location is vertically biased on device (safe-area handling), which
        // shifted marker hit-testing below the drawn icons.
        if let nativeTap = lastNativeTapPoint,
           ProcessInfo.processInfo.systemUptime - lastNativeTapUptime < 1.5,
           let geo = unprojectFromScreen(nativeTap) {
            lastNativeTapPoint = nil
            handleClick(geo.clLocation)
            return
        }
        let result = map.call(method: "location", args: [map.ldstatic("LocationMode", with: "Pointer")])
        handleClick(result)
    }

    private func handleClick(_ result: Any?) {
        guard let point = Self.geoPoint(from: result) else { return }
        // Markers are hit-tested from the click coordinates (their DOM elements pass taps
        // through); a consumed tap behaves like the other providers — no map-click.
        // marker → circle → groundImage → polyline → polygon → map の一本道。
        // **必ずどれか 1 つだけ**が配送される。
        // 移行前はここで onMapClick を無条件に先に呼んでいたため、オーバーレイに
        // 当たっても地図クリックが飛んでいた（二重配送）。
        if overlayBinding?.handleMarkerTap(point) == true { return }
        if overlayBinding?.handleTap(point) == true { return }
        onMapClick?(point)
        controller?.notifyMapClick(point)
    }

    private static func geoPoint(from result: Any?) -> GeoPoint? {
        if let coord = result as? CLLocationCoordinate2D {
            return GeoPoint(latitude: coord.latitude, longitude: coord.longitude, altitude: 0)
        }
        if let dict = result as? [String: Any] {
            let lat = doubleValue(dict["lat"]) ?? doubleValue(dict["latitude"])
            let lon = doubleValue(dict["lon"]) ?? doubleValue(dict["longitude"])
            if let lat, let lon { return GeoPoint(latitude: lat, longitude: lon, altitude: 0) }
        }
        return nil
    }

    static func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let i = value as? Int { return Double(i) }
        return nil
    }
}
