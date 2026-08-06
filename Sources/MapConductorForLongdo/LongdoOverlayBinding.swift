import CoreGraphics
import Foundation
import MapConductorCore

/// Owns and drives the Longdo overlay controllers, all using the official SDK's native overlay
/// objects (`longdo.Polyline` / `Polygon` / `Circle` / `Marker` / `Rectangle` / `Layer`):
/// - vector overlays (polyline / polygon / circle / ground image / raster) via the per-type core
///   controllers + renderers;
/// - markers via ``LongdoMarkerController``.
///
/// The map-view coordinator forwards content sync, taps, camera changes and overlay events here.
@MainActor
final class LongdoOverlayBinding {
    private let scope: MapOverlayScope

    private let polylineController: LongdoPolylineController
    private let polygonController: LongdoPolygonController
    private let circleController: LongdoCircleController
    private let groundImageController: LongdoGroundImageController
    private let rasterController: LongdoRasterLayerController
    private let markerController: LongdoMarkerController

    private var ready = false
    private var lastMarkers: [MarkerState] = []

    /// クラスタリングが接続されている間の描画対象。`nil` のときは通常の `content.markers`。
    ///
    /// android-for-longdo では `LongdoClusterMarkerRenderer` が `_markers` フローを
    /// 差し替えることでコンポーズオーバーレイの描画対象を切り替えている。iOS も同じく、
    /// クラスタ側が算出した「クラスタ＋可視単体」だけを描くために content のマーカーを覆う。
    private var clusterMarkers: [MarkerState]?

    /// Bridge kept to build the marker-tile Custom layer lazily (created only for large sets).
    private weak var bridge: LongdoBridge?
    /// Marker tiling options from the latest content sync.
    private var lastTiling: MarkerTilingOptions = .Disabled
    /// Latest camera, used to derive the native zoom for tiled-marker tap hit-testing.
    private var lastCamera: MapCameraPosition?
    /// Renders large, non-interactive marker sets as raster tiles (created on demand).
    private var markerTileRenderer: LongdoMarkerTileRenderer?

    init(bridge: LongdoBridge, scope: MapOverlayScope, controller: LongdoViewController) {
        self.bridge = bridge
        self.scope = scope
        self.polylineController = LongdoPolylineController(bridge: bridge)
        self.polygonController = LongdoPolygonController(bridge: bridge)
        self.circleController = LongdoCircleController(bridge: bridge)
        self.groundImageController = LongdoGroundImageController(bridge: bridge)
        self.rasterController = LongdoRasterLayerController(bridge: bridge)
        self.markerController = LongdoMarkerController(bridge: bridge)

        scope.polylineCollector.setShouldApply { [weak self] in self?.ready ?? false }
        scope.polygonCollector.setShouldApply { [weak self] in self?.ready ?? false }
        scope.circleCollector.setShouldApply { [weak self] in self?.ready ?? false }
        scope.groundImageCollector.setShouldApply { [weak self] in self?.ready ?? false }
        scope.rasterLayerCollector.setShouldApply { [weak self] in self?.ready ?? false }

        bindOverlayCollector(scope.polylineCollector, to: polylineController)
        bindOverlayCollector(scope.polygonCollector, to: polygonController)
        bindOverlayCollector(scope.circleCollector, to: circleController)
        bindOverlayCollector(scope.groundImageCollector, to: groundImageController)
        bindOverlayCollector(scope.rasterLayerCollector, to: rasterController)
    }

    func sync(_ content: MapViewContent) {
        scope.polylineCollector.sync(content.polylines.map { $0.state })
        scope.polygonCollector.sync(content.polygons.map { $0.state })
        scope.circleCollector.sync(content.circles.map { $0.state })
        scope.groundImageCollector.sync(content.groundImages.map { $0.state })
        scope.rasterLayerCollector.sync(content.rasterLayers.map { $0.state })
        lastMarkers = content.markers.map { $0.state }
        lastTiling = content.markerTilingOptions
        if ready { applyMarkers() }
    }

    /// クラスタリングが算出したマーカー一覧を反映する。`nil` を渡すと通常の content 経路へ戻す。
    func setClusterMarkers(_ markers: [MarkerState]?) {
        clusterMarkers = markers
        if ready { applyMarkers() }
    }

    /// Mark the map ready: flush gated collectors and apply markers now the SDK can accept overlays.
    func markReady() {
        ready = true
        scope.polylineCollector.flush()
        scope.polygonCollector.flush()
        scope.circleCollector.flush()
        scope.groundImageCollector.flush()
        scope.rasterLayerCollector.flush()
        applyMarkers()
    }

    /// Routes markers to the raster-tile path (large, non-interactive sets) or the interactive
    /// DOM-marker path. Draggable/animated markers always stay on the DOM path (a raster tile
    /// cannot be dragged/animated); the rest tile once they exceed `minMarkerCount`. Mirrors
    /// android-for-longdo's `useMarkerLayer` split so the "Bunch of markers" page renders one
    /// raster layer instead of thousands of DOM markers.
    private func applyMarkers() {
        // クラスタ接続中はクラスタ側の算出結果だけを描く。タイル化はクラスタと二重に
        // 間引くことになるので行わない（android も同様にコンポーズオーバーレイへ直行する）。
        if let clusterMarkers {
            markerTileRenderer?.clear()
            markerTileRenderer = nil
            markerController.sync(clusterMarkers)
            return
        }
        let interactive = lastMarkers.filter { $0.draggable || $0.getAnimation() != nil }
        let tileable = lastMarkers.filter { !$0.draggable && $0.getAnimation() == nil }
        let useTiling = lastTiling.enabled && tileable.count >= lastTiling.minMarkerCount
        if useTiling {
            ensureMarkerTileRenderer().render(tileable)
            markerController.sync(interactive)
        } else {
            markerTileRenderer?.clear()
            markerTileRenderer = nil
            markerController.sync(lastMarkers)
        }
    }

    private func ensureMarkerTileRenderer() -> LongdoMarkerTileRenderer {
        if let markerTileRenderer { return markerTileRenderer }
        let renderer = LongdoMarkerTileRenderer(bridge: bridge, tilingOptions: lastTiling)
        markerTileRenderer = renderer
        return renderer
    }

    func setCurrentCamera(_ camera: MapCameraPosition) {
        lastCamera = camera
        polylineController.setCurrentCameraPosition(camera)
    }

    /// Current state for a marker id (used by the info-bubble coordinator to resolve icons).
    func markerState(for id: String) -> MarkerState? {
        markerController.getMarkerState(for: id)
    }

    /// Supplies the geo→view projection used for marker tap hit-testing.
    func setMarkerProjector(_ projector: @escaping (GeoPointProtocol) -> CGPoint?) {
        markerController.projector = projector
    }

    /// Supplies the screen-space marker animation layer (drop/bounce) shared with the other
    /// providers; the native DOM marker stays hidden while its icon animates on the overlay.
    func setMarkerAnimationOverlay(_ overlay: MarkerAnimationOverlayCoordinator?) {
        markerController.animationOverlay = overlay
    }

    /// Hit-tests a map click against markers; returns true when a marker consumed the tap.
    /// Interactive DOM markers are tested first, then (for large sets) the tiled markers via a
    /// geo-distance hit-test at the current native zoom.
    func handleMarkerTap(_ point: GeoPoint) -> Bool {
        if markerController.handleTap(point) { return true }
        if let tileRenderer = markerTileRenderer, let camera = lastCamera {
            let nativeZoom = LongdoViewController.coreZoomToLongdo(camera.zoom)
            if let hit = tileRenderer.findMarkerAt(point, nativeZoom: nativeZoom) {
                if hit.clickable { hit.onClick?(hit) }
                return true
            }
        }
        return false
    }

    // MARK: - Custom marker drag (long-press pickup)

    func hasDraggableMarker(at point: CGPoint) -> Bool {
        markerController.hasDraggableMarker(at: point)
    }

    func beginMarkerDrag(at point: CGPoint) -> Bool {
        markerController.beginDrag(at: point)
    }

    func updateMarkerDrag(to position: GeoPoint) {
        markerController.updateDrag(to: position)
    }

    func endMarkerDrag(at position: GeoPoint?) {
        markerController.endDrag(at: position)
    }

    /// Observer notified with the marker id whenever a custom drag moves a marker.
    func setMarkerDragObserver(_ observer: @escaping (String) -> Void) {
        markerController.onDragVisualUpdate = observer
    }

    /// Route a native overlay event (marker click/drag) from the SDK bridge.
    func handleOverlayEvent(event: String, result: Any?) {
        markerController.handleOverlayEvent(event: event, result: result)
    }

    /// Route a map tap to vector-overlay hit testing (markers use their own native overlay events).
    func handleTap(_ point: GeoPoint) {
        if let hit = circleController.find(position: point) {
            circleController.dispatchClick(event: CircleEvent(state: hit.state, clicked: point))
        }
        if let hit = polylineController.findWithClosestPoint(position: point) {
            polylineController.dispatchClick(event: PolylineEvent(state: hit.entity.state, clicked: hit.closestPoint))
        }
        if let hit = polygonController.find(position: point) {
            polygonController.dispatchClick(event: PolygonEvent(state: hit.state, clicked: point))
        }
        if let hit = groundImageController.find(position: point) {
            groundImageController.dispatchClick(event: GroundImageEvent(state: hit.state, clicked: point))
        }
    }

    func unbind() {
        markerController.clear()
        markerTileRenderer?.clear()
        markerTileRenderer = nil
        Task {
            await polylineController.clear()
            await polygonController.clear()
            await circleController.clear()
            await groundImageController.clear()
        }
        polylineController.destroy()
        polygonController.destroy()
        circleController.destroy()
        groundImageController.destroy()
        rasterController.destroy()
    }
}
