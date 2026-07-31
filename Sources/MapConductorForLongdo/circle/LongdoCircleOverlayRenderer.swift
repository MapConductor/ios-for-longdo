import CoreLocation
import Foundation
import LongdoMapFramework
import MapConductorCore

/// Handle to a Longdo circle: the native `longdo.Polygon` overlay(s) approximating the circle.
final class LongdoCircleHandle {
    var objects: [LongdoMap.LDObject]
    init(objects: [LongdoMap.LDObject]) { self.objects = objects }
}

/// Renders circles as native Longdo overlays. Longdo's `longdo.Circle` radius unit is ambiguous, so
/// a geodesic polygon ring is generated from center + radius (meters) and drawn as a
/// `longdo.Polygon`. Hit testing is done by the core `CircleManager`.
@MainActor
final class LongdoCircleOverlayRenderer: AbstractCircleOverlayRenderer<LongdoCircleHandle> {
    private weak var bridge: LongdoBridge?
    private let segments = 128

    init(bridge: LongdoBridge?) {
        self.bridge = bridge
        super.init()
    }

    override func createCircle(state: CircleState) async -> LongdoCircleHandle? {
        let objects = build(state)
        return objects.isEmpty ? nil : LongdoCircleHandle(objects: objects)
    }

    override func updateCircleProperties(
        circle: LongdoCircleHandle,
        current: CircleEntity<LongdoCircleHandle>,
        prev: CircleEntity<LongdoCircleHandle>
    ) async -> LongdoCircleHandle? {
        // Rebuilding a Longdo overlay flickers; skip untouched states (see polyline renderer).
        if current.fingerPrint == prev.fingerPrint { return circle }
        remove(circle.objects)
        circle.objects = build(current.state)
        return circle
    }

    override func removeCircle(entity: CircleEntity<LongdoCircleHandle>) async {
        if let handle = entity.circle { remove(handle.objects) }
    }

    func reapply(_ handles: [LongdoCircleHandle]) {}

    private func build(_ state: CircleState) -> [LongdoMap.LDObject] {
        guard let bridge, state.radiusMeters > 0 else { return [] }
        let ring = (0..<segments).map { i -> GeoPointProtocol in
            Spherical.computeOffset(origin: state.center, distance: state.radiusMeters, heading: 360.0 * Double(i) / Double(segments))
        }
        let segmentsList = longdoSegments(ring, geodesic: true, minCount: 3)
        guard !segmentsList.isEmpty else { return [] }
        let options: [String: Any] = [
            "lineWidth": state.strokeWidth,
            "lineColor": state.strokeColor,
            "fillColor": state.fillColor,
        ]
        var objects: [LongdoMap.LDObject] = []
        for seg in segmentsList {
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

/// Longdo circle controller. Diffing/state/click hit-testing come from the core `CircleController`;
/// drawing is delegated to ``LongdoCircleOverlayRenderer``.
@MainActor
final class LongdoCircleController: CircleController<LongdoCircleHandle, LongdoCircleOverlayRenderer> {
    init(bridge: LongdoBridge?) {
        super.init(circleManager: CircleManager<LongdoCircleHandle>(), renderer: LongdoCircleOverlayRenderer(bridge: bridge))
    }

    func reapply() {}
}
