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

    init(bridge: LongdoBridge, scope: MapOverlayScope, controller: LongdoViewController) {
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
        if ready { markerController.sync(lastMarkers) }
    }

    /// Mark the map ready: flush gated collectors and apply markers now the SDK can accept overlays.
    func markReady() {
        ready = true
        scope.polylineCollector.flush()
        scope.polygonCollector.flush()
        scope.circleCollector.flush()
        scope.groundImageCollector.flush()
        scope.rasterLayerCollector.flush()
        markerController.sync(lastMarkers)
    }

    func setCurrentCamera(_ camera: MapCameraPosition) {
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
    func handleMarkerTap(_ point: GeoPoint) -> Bool {
        markerController.handleTap(point)
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
