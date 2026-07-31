import CoreLocation
import Foundation
import LongdoMapFramework
import MapConductorCore
import UIKit

/// Handle to a Longdo ground image: a native `longdo.Rectangle` overlay with an image `texture`.
final class LongdoGroundImageHandle {
    var object: LongdoMap.LDObject?
    init(object: LongdoMap.LDObject?) { self.object = object }
}

/// Renders ground images as a native `longdo.Rectangle` with a `texture` (the demo's
/// "Add Image as Layer" pattern) — Longdo's native way to place an image over a bounds. Hit testing
/// is done by the core `GroundImageManager`.
@MainActor
final class LongdoGroundImageOverlayRenderer: AbstractGroundImageOverlayRenderer<LongdoGroundImageHandle> {
    private weak var bridge: LongdoBridge?

    init(bridge: LongdoBridge?) {
        self.bridge = bridge
        super.init()
    }

    override func createGroundImage(state: GroundImageState) async -> LongdoGroundImageHandle? {
        LongdoGroundImageHandle(object: build(state))
    }

    override func updateGroundImageProperties(
        groundImage: LongdoGroundImageHandle,
        current: GroundImageEntity<LongdoGroundImageHandle>,
        prev: GroundImageEntity<LongdoGroundImageHandle>
    ) async -> LongdoGroundImageHandle? {
        // Rebuilding a Longdo overlay flickers; skip untouched states (see polyline renderer).
        if current.fingerPrint == prev.fingerPrint { return groundImage }
        if let obj = groundImage.object { bridge?.call("Overlays.remove", args: [obj]) }
        groundImage.object = build(current.state)
        return groundImage
    }

    override func removeGroundImage(entity: GroundImageEntity<LongdoGroundImageHandle>) async {
        if let obj = entity.groundImage?.object { bridge?.call("Overlays.remove", args: [obj]) }
    }

    func reapply(_ handles: [LongdoGroundImageHandle]) {}

    private func build(_ state: GroundImageState) -> LongdoMap.LDObject? {
        guard let bridge, let sw = state.bounds.southWest, let ne = state.bounds.northEast else { return nil }
        let topLeft = CLLocationCoordinate2D(latitude: ne.latitude, longitude: sw.longitude)
        let size = CGSize(width: ne.longitude - sw.longitude, height: ne.latitude - sw.latitude)
        let options: [String: Any] = [
            "lineWidth": 0,
            "lineColor": UIColor.clear,
            "fillColor": UIColor.clear,
            "texture": state.image,
            "textureAlpha": state.opacity,
        ]
        let obj = bridge.ldobject("Rectangle", with: [topLeft, size, options])
        bridge.call("Overlays.add", args: [obj])
        return obj
    }
}

/// Longdo ground image controller. Diffing/state/click hit-testing come from the core
/// `GroundImageController`; drawing is delegated to ``LongdoGroundImageOverlayRenderer``.
@MainActor
final class LongdoGroundImageController: GroundImageController<LongdoGroundImageHandle, LongdoGroundImageOverlayRenderer> {
    init(bridge: LongdoBridge?) {
        super.init(groundImageManager: GroundImageManager<LongdoGroundImageHandle>(), renderer: LongdoGroundImageOverlayRenderer(bridge: bridge))
    }

    func reapply() {}
}
