import CoreLocation
import Foundation
import LongdoMapFramework
import MapConductorCore

/// Handle to a Longdo polygon: the native `longdo.Polygon` overlay objects added to `map.Overlays`.
final class LongdoPolygonHandle {
    var objects: [LongdoMap.LDObject]
    init(objects: [LongdoMap.LDObject]) { self.objects = objects }
}

/// Renders polygons as native `longdo.Polygon` overlays. Holes are drawn as nil-separated
/// additional rings (Longdo's native donut convention). Hit testing is done by the core
/// `PolygonManager`.
@MainActor
final class LongdoPolygonOverlayRenderer: AbstractPolygonOverlayRenderer<LongdoPolygonHandle> {
    private weak var bridge: LongdoBridge?

    init(bridge: LongdoBridge?) {
        self.bridge = bridge
        super.init()
    }

    override func createPolygon(state: PolygonState) async -> LongdoPolygonHandle? {
        let objects = build(state)
        return objects.isEmpty ? nil : LongdoPolygonHandle(objects: objects)
    }

    override func updatePolygonProperties(
        polygon: LongdoPolygonHandle,
        current: PolygonEntity<LongdoPolygonHandle>,
        prev: PolygonEntity<LongdoPolygonHandle>
    ) async -> LongdoPolygonHandle? {
        // Rebuilding a Longdo overlay flickers; skip untouched states (see polyline renderer).
        if current.fingerPrint == prev.fingerPrint { return polygon }
        remove(polygon.objects)
        polygon.objects = build(current.state)
        return polygon
    }

    override func removePolygon(entity: PolygonEntity<LongdoPolygonHandle>) async {
        if let handle = entity.polygon { remove(handle.objects) }
    }

    func reapply(_ handles: [LongdoPolygonHandle]) {}

    private func build(_ state: PolygonState) -> [LongdoMap.LDObject] {
        guard let bridge, state.points.count >= 3 else { return [] }
        let outerSegments = longdoSegments(state.points, geodesic: state.geodesic, minCount: 3)
        guard !outerSegments.isEmpty else { return [] }
        let options: [String: Any] = [
            "lineWidth": state.strokeWidth,
            "lineColor": state.strokeColor,
            "fillColor": state.fillColor,
        ]

        // Single outer ring + holes → one Polygon with nil-separated hole rings.
        if !state.holes.isEmpty, outerSegments.count == 1 {
            var points: [CLLocationCoordinate2D?] = outerSegments[0].map { $0 }
            for hole in state.holes {
                let ring = longdoRingCoords(hole, geodesic: state.geodesic)
                if ring.count >= 3 {
                    points.append(nil)
                    points.append(contentsOf: ring.map { $0 })
                }
            }
            let obj = bridge.ldobject("Polygon", with: [points, options])
            bridge.call("Overlays.add", args: [obj])
            return [obj]
        }

        // No holes (or antimeridian-split) → one Polygon per outer ring.
        var objects: [LongdoMap.LDObject] = []
        for seg in outerSegments {
            let obj = bridge.ldobject("Polygon", with: [seg, options])
            bridge.call("Overlays.add", args: [obj])
            objects.append(obj)
        }
        return objects
    }

    private func remove(_ objects: [LongdoMap.LDObject]) {
        for obj in objects { bridge?.call("Overlays.remove", args: [obj]) }
    }
}

/// Longdo polygon controller. Diffing/state/hit-testing come from the core `PolygonController`;
/// drawing is delegated to ``LongdoPolygonOverlayRenderer``.
@MainActor
final class LongdoPolygonController: PolygonController<LongdoPolygonHandle, LongdoPolygonOverlayRenderer> {
    init(bridge: LongdoBridge?) {
        super.init(polygonManager: PolygonManager<LongdoPolygonHandle>(), renderer: LongdoPolygonOverlayRenderer(bridge: bridge))
    }

    func reapply() {}
}
