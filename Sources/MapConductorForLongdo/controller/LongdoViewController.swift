import CoreLocation
import Foundation
import MapConductorCore

/// Bridges MapConductor core to the official Longdo Map iOS SDK (`LongdoMap`). Camera operations are
/// issued through the SDK bridge (`location` / `zoom` / `rotate` / `pitch` / `bound`); overlays live
/// in separate controllers. Camera ops requested before the map is `ready` are stashed in
/// ``pendingCameraPosition`` and applied on ``onMapReady()``. Mirrors android-for-longdo's
/// `LongdoMapViewController`.
final class LongdoViewController: MapViewControllerProtocol {
    let holder: AnyMapViewHolder
    let typedHolder: LongdoMapViewHolder
    let coroutine = CoroutineScope()

    /// この地図に紐づくオーバーレイコントローラの登録簿。
    /// 拡張モジュール（ヒートマップ、マーカークラスタリング等）がここに登録して
    /// カメラ変更を受け取る。`MapViewControllerProtocol` の要件。
    let overlayControllers = OverlayControllerRegistry()

    private weak var bridge: LongdoBridge?
    private let zoomConverter = ZoomAltitudeConverter()

    private var cameraMoveStartListener: OnCameraMoveHandler?
    private var cameraMoveListener: OnCameraMoveHandler?
    private var cameraMoveEndListener: OnCameraMoveHandler?

    /// Longdo はネイティブのカメラ範囲制限 API を（統一ズームの体系で）持たないため、
    /// android-sdk の HERE/ArcGIS/TomTom と同じくカメラ停止時に矩形内へクランプして
    /// 再適用する方式で制限する。
    private let cameraRestrictionClamp = CameraRestrictionClamp()

    func setCameraRestriction(_ restriction: CameraRestriction?) {
        cameraRestrictionClamp.set(restriction)
    }
    private var mapClickListener: OnMapEventHandler?
    private var mapLongClickListener: OnMapEventHandler?
    private var mapInitializedListener: OnMapInitializedHandler?

    private var mapReady = false
    private var pendingCameraPosition: MapCameraPosition?

    /// Echo-filter state: the camera we expect Longdo to report after the most recent
    /// programmatic apply. See ``shouldSuppressCameraEcho(_:)``.
    private var echoTarget: MapCameraPosition?
    private var echoTargetReached = false
    private var echoLastCamera: MapCameraPosition?
    private var echoStableStreak = 0
    private var echoUnconvergedEvents = 0

    init(holder: LongdoMapViewHolder, bridge: LongdoBridge) {
        self.typedHolder = holder
        self.holder = AnyMapViewHolder(holder)
        self.bridge = bridge
    }

    // MARK: - Lifecycle

    func onMapReady() {
        mapReady = true
        if let pending = pendingCameraPosition {
            applyCamera(pending)
            pendingCameraPosition = nil
        }
    }

    // MARK: - MapViewControllerProtocol

    func clearOverlays() async {}

    func setCameraMoveStartListener(listener: OnCameraMoveHandler?) { cameraMoveStartListener = listener }
    func setCameraMoveListener(listener: OnCameraMoveHandler?) { cameraMoveListener = listener }
    func setCameraMoveEndListener(listener: OnCameraMoveHandler?) { cameraMoveEndListener = listener }
    func setMapClickListener(listener: OnMapEventHandler?) { mapClickListener = listener }
    func setMapLongClickListener(listener: OnMapEventHandler?) { mapLongClickListener = listener }
    func setMapInitializedListener(listener: OnMapInitializedHandler?) { mapInitializedListener = listener }

    func moveCamera(position: MapCameraPosition) {
        if mapReady { applyCamera(position) } else { pendingCameraPosition = position }
    }

    func animateCamera(position: MapCameraPosition, duration: Long) {
        // Longdo's bridge animates center and zoom with separate commands; issuing both animated
        // makes the later zoom cut off the pan. Camera sync follows the source's continuous events,
        // so apply the resolved position instantly (parity with android-for-longdo).
        if mapReady { applyCamera(position) } else { pendingCameraPosition = position }
    }

    func fitBounds(bounds: GeoRectBounds, padding: Int) {
        guard mapReady, let sw = bounds.southWest, let ne = bounds.northEast else { return }
        bridge?.call("bound", args: [[
            "minLat": sw.latitude, "maxLat": ne.latitude,
            "minLon": sw.longitude, "maxLon": ne.longitude,
        ]])
    }

    /// Switches the base layer at runtime.
    func setMapDesignType(_ design: LongdoMapDesignType) {
        guard let bridge, mapReady else { return }
        bridge.call("Layers.setBase", args: [bridge.ldstatic("Layers", with: design.layerName)])
    }

    // MARK: - Camera application

    private struct NativeCamera {
        let target: GeoPointProtocol
        let longdoZoom: Double
        let pitch: Double
    }

    private func applyCamera(_ position: MapCameraPosition) {
        guard let bridge else { return }
        let native = nativeCameraFor(position)
        // What we expect Longdo to report back for this apply, in core-camera terms
        // (nativeCameraFor may offset the target and flip the pitch sign for negative tilt;
        // the zoom is round-tripped through the native clamp so a clamped apply still converges).
        echoTarget = MapCameraPosition(
            position: GeoPoint(latitude: native.target.latitude, longitude: native.target.longitude, altitude: 0),
            zoom: Self.longdoZoomToCore(native.longdoZoom),
            bearing: position.bearing,
            tilt: native.pitch
        )
        echoTargetReached = false
        echoLastCamera = nil
        echoStableStreak = 0
        echoUnconvergedEvents = 0
        bridge.call("location", args: [native.target.clLocation, false])
        bridge.call("zoom", args: [native.longdoZoom, false])
        bridge.call("rotate", args: [position.bearing, false])
        bridge.call("pitch", args: [native.pitch])
    }

    private func nativeCameraFor(_ position: MapCameraPosition) -> NativeCamera {
        let longdoZoom = Self.coreZoomToLongdo(position.zoom)
        if position.tilt >= 0.0 {
            return NativeCamera(target: position.position, longdoZoom: longdoZoom, pitch: longdoClamp(position.tilt, 0.0, Self.maxPitch))
        }
        let tiltAbsDeg = longdoClamp(abs(position.tilt), 0.0, Self.maxPitch)
        let tiltAbsRad = tiltAbsDeg * .pi / 180.0
        let altitude = zoomConverter.zoomLevelToAltitude(zoomLevel: position.zoom, latitude: position.position.latitude, tilt: 0.0)
        let distanceForward = altitude * tan(tiltAbsRad)
        let target = Spherical.computeOffset(origin: position.position, distance: distanceForward, heading: position.bearing)
        return NativeCamera(target: target, longdoZoom: longdoZoom, pitch: tiltAbsDeg)
    }

    // MARK: - Programmatic echo filtering

    /// Longdo re-emits camera events for moves we applied programmatically. If those echoes were
    /// dispatched as regular camera callbacks, a *synced* Longdo would feed its own camera back to
    /// the source map and the two maps could chase each other indefinitely. This filter is
    /// deterministic (event-content based, no wall clock): after ``applyCamera(_:)`` every event is
    /// compared against the applied target — events at the target are our own echoes and are
    /// swallowed; once the target has been reached, the first event that *differs* is a real user
    /// gesture and is dispatched.
    ///
    /// While the target has NOT been reached, a mismatched camera is never dispatched: the WebView
    /// applies `location`/`zoom`/`rotate`/`pitch` asynchronously, so mismatches are half-applied
    /// intermediate states (e.g. new center with the old zoom on a slow device) — feeding one back
    /// would drag the source map off target. If the map settles *off* target (clamped bearing/pitch,
    /// interrupted move), we detect that as the same camera repeated over several events and release
    /// the filter — still swallowing that settled camera, since it is the outcome of our own apply —
    /// so subsequent user gestures sync normally.
    func shouldSuppressCameraEcho(_ camera: MapCameraPosition) -> Bool {
        guard let target = echoTarget else { return false }
        defer { echoLastCamera = camera }
        if Self.isCameraAtTarget(camera, target) {
            echoTargetReached = true
            echoStableStreak = 0
            return true
        }
        if echoTargetReached {
            clearEchoFilter()
            return false
        }
        if let last = echoLastCamera, Self.isCameraUnchanged(camera, last) {
            echoStableStreak += 1
            if echoStableStreak >= Self.echoSettleStreak { clearEchoFilter() }
        } else {
            echoStableStreak = 0
        }
        // Backstop for an unreachable target that never settles into identical events (so neither
        // release above fires): after many consecutive unconverged events give up on the target so
        // user gestures aren't suppressed forever. High enough that a slow device converging on a
        // real target (a handful of events after the final apply) never trips it.
        echoUnconvergedEvents += 1
        if echoUnconvergedEvents >= Self.echoUnconvergedRelease { clearEchoFilter() }
        return true
    }

    private func clearEchoFilter() {
        echoTarget = nil
        echoTargetReached = false
        echoLastCamera = nil
        echoStableStreak = 0
        echoUnconvergedEvents = 0
    }

    /// One programmatic apply triggers up to four events (Location/Zoom/Rotate/Pitch) that can all
    /// carry the same half-applied camera, so the settle streak must exceed that count.
    private static let echoSettleStreak = 5
    private static let echoUnconvergedRelease = 30

    private static func isCameraAtTarget(_ camera: MapCameraPosition, _ target: MapCameraPosition) -> Bool {
        // ~24px position tolerance at the target zoom; 0.6 zoom levels absorbs Longdo's
        // half-step zoom snapping after the core<->longdo conversion.
        let degPerPixel = 360.0 / (256.0 * pow(2.0, max(target.zoom, 1.0)))
        let positionTolerance = degPerPixel * 24.0
        let lonDiff = abs(camera.position.longitude - target.position.longitude).truncatingRemainder(dividingBy: 360)
        let lonDelta = lonDiff > 180 ? 360 - lonDiff : lonDiff
        let bearingDiff = abs(camera.bearing - target.bearing).truncatingRemainder(dividingBy: 360)
        let bearingDelta = bearingDiff > 180 ? 360 - bearingDiff : bearingDiff
        return abs(camera.position.latitude - target.position.latitude) <= positionTolerance &&
            lonDelta <= positionTolerance &&
            abs(camera.zoom - target.zoom) <= 0.6 &&
            bearingDelta <= 5.0 &&
            abs(camera.tilt - target.tilt) <= 3.0
    }

    /// Tight equality used for settle detection: the map reports the same camera event-over-event.
    private static func isCameraUnchanged(_ a: MapCameraPosition, _ b: MapCameraPosition) -> Bool {
        abs(a.position.latitude - b.position.latitude) <= 1e-7 &&
            abs(a.position.longitude - b.position.longitude) <= 1e-7 &&
            abs(a.zoom - b.zoom) <= 0.01 &&
            abs(a.bearing - b.bearing) <= 0.1 &&
            abs(a.tilt - b.tilt) <= 0.1
    }

    // MARK: - Event notification (called by the coordinator)

    func notifyCameraMoveStart(_ cameraPosition: MapCameraPosition) { cameraMoveStartListener?(cameraPosition) }
    func notifyCameraMove(_ cameraPosition: MapCameraPosition) { cameraMoveListener?(cameraPosition) }
    func notifyCameraMoveEnd(_ cameraPosition: MapCameraPosition) {
        // 登録済みオーバーレイ（拡張モジュール含む）へ伝播する。
        overlayControllers.dispatchCameraChanged(cameraPosition)
        cameraMoveEndListener?(cameraPosition)
    }

    /// カメラ停止時に制限違反を補正する。補正したら `true`。
    ///
    /// android-sdk は補正時に `cameraMoveEndCallback` を呼ばずに return するので、アプリ側は
    /// 範囲外のカメラを観測しない。iOS はカメラ通知経路がビュー側にもあるため、ビューが
    /// まずこれを呼び、`true` なら state 更新・リスナー通知をまとめてスキップする。
    func applyCameraRestrictionCorrectionIfNeeded(_ current: MapCameraPosition) -> Bool {
        guard let corrected = cameraRestrictionClamp.correction(for: current) else { return false }
        moveCamera(position: corrected)
        return true
    }
    func notifyMapClick(_ point: GeoPoint) {
        mapClickListener?(point)
    }
    func notifyMapLongClick(_ point: GeoPoint) { mapLongClickListener?(point) }
    func notifyMapInitialized() { mapInitializedListener?(.MapCreated) }

    // MARK: - Zoom conversion

    /// Longdo native zoom is one step smaller than the unified (Google) zoom:
    /// `GoogleZoom ≈ LongdoZoom + 1.0`. Matches the MapLibre provider so Camera Sync agrees.
    private static let longdoToGoogleZoomOffset = 1.0
    private static let minZoom = 1.0
    private static let maxZoom = 20.0
    private static let maxPitch = 60.0

    static func coreZoomToLongdo(_ coreZoom: Double) -> Double {
        longdoClamp(coreZoom - longdoToGoogleZoomOffset, minZoom, maxZoom)
    }

    static func longdoZoomToCore(_ longdoZoom: Double) -> Double {
        longdoClamp(longdoZoom + longdoToGoogleZoomOffset, minZoom, maxZoom)
    }
}
