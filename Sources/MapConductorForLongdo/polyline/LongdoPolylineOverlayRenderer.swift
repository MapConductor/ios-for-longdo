import Foundation
import LongdoMapFramework
import MapConductorCore

/// Handle to a Longdo polyline: the native `longdo.Polyline` overlay objects (one per
/// antimeridian-split segment) added to `map.Overlays`.
final class LongdoPolylineHandle {
    var objects: [LongdoMap.LDObject]
    init(objects: [LongdoMap.LDObject]) { self.objects = objects }
}

/// Renders polylines as native `longdo.Polyline` overlays (`map.Overlays.add`). Geodesic
/// interpolation and antimeridian splitting reuse the core utilities; hit testing is done by the
/// core `PolylineManager`.
@MainActor
final class LongdoPolylineOverlayRenderer: AbstractPolylineOverlayRenderer<LongdoPolylineHandle> {
    private weak var bridge: LongdoBridge?

    init(bridge: LongdoBridge?) {
        self.bridge = bridge
        super.init()
    }

    override func createPolyline(state: PolylineState) async -> LongdoPolylineHandle? {
        let objects = build(state)
        return objects.isEmpty ? nil : LongdoPolylineHandle(objects: objects)
    }

    override func updatePolylineProperties(
        polyline: LongdoPolylineHandle,
        current: PolylineEntity<LongdoPolylineHandle>,
        prev: PolylineEntity<LongdoPolylineHandle>
    ) async -> LongdoPolylineHandle? {
        // Longdo can only rebuild (remove + re-add) native overlays, which visibly flickers,
        // so skip untouched states (every content sync routes identical states through here).
        if current.fingerPrint == prev.fingerPrint { return polyline }
        remove(polyline.objects)
        polyline.objects = build(current.state)
        return polyline
    }

    override func removePolyline(entity: PolylineEntity<LongdoPolylineHandle>) async {
        if let handle = entity.polyline { remove(handle.objects) }
    }

    func reapply(_ handles: [LongdoPolylineHandle]) {}

    private func build(_ state: PolylineState) -> [LongdoMap.LDObject] {
        guard let bridge else { return [] }
        let segments = longdoSegments(state.points, geodesic: state.geodesic, minCount: 2)
        let options: [String: Any] = ["lineWidth": state.strokeWidth, "lineColor": state.strokeColor]
        var objects: [LongdoMap.LDObject] = []
        for seg in segments {
            let obj = bridge.ldobject("Polyline", with: [seg, options])
            bridge.call("Overlays.add", args: [obj])
            objects.append(obj)
        }
        return objects
    }

    private func remove(_ objects: [LongdoMap.LDObject]) {
        for obj in objects { bridge?.call("Overlays.remove", args: [obj]) }
    }
}

/// Longdo polyline controller. Diffing/state/hit-testing come from the core `PolylineController`;
/// drawing is delegated to ``LongdoPolylineOverlayRenderer``.
@MainActor
final class LongdoPolylineController: PolylineController<LongdoPolylineHandle, LongdoPolylineOverlayRenderer> {
    init(bridge: LongdoBridge?) {
        super.init(polylineManager: PolylineManager<LongdoPolylineHandle>(), renderer: LongdoPolylineOverlayRenderer(bridge: bridge))
    }

    func reapply() {}
}
