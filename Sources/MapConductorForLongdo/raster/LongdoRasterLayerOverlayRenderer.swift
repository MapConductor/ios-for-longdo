import Foundation
import LongdoMapFramework
import MapConductorCore

/// Handle to a Longdo raster layer: a native `longdo.Layer` (custom tile layer) added via `Layers.add`.
final class LongdoRasterLayerHandle {
    var object: LongdoMap.LDObject?
    init(object: LongdoMap.LDObject?) { self.object = object }
}

/// Renders raster layers as native `longdo.Layer` custom tile layers. `UrlTemplate` sources map to
/// a Custom layer (`{z}/{x}/{y}` URL); `TileJson`/`ArcGisService` are not natively supported here.
@MainActor
final class LongdoRasterLayerOverlayRenderer: AbstractRasterLayerOverlayRenderer<LongdoRasterLayerHandle> {
    private weak var bridge: LongdoBridge?

    init(bridge: LongdoBridge?) {
        self.bridge = bridge
        super.init()
    }

    override func createLayer(state: RasterLayerState) async -> LongdoRasterLayerHandle? {
        RasterHeaderRuleSet.warnUnsupported(provider: "Longdo", state: state)
        return LongdoRasterLayerHandle(object: build(state))
    }

    override func updateLayerProperties(
        layer: LongdoRasterLayerHandle,
        current: RasterLayerEntity<LongdoRasterLayerHandle>,
        prev: RasterLayerEntity<LongdoRasterLayerHandle>
    ) async -> LongdoRasterLayerHandle? {
        // Rebuilding a Longdo layer flickers; skip untouched states (see polyline renderer).
        if current.fingerPrint == prev.fingerPrint { return layer }
        if let obj = layer.object { bridge?.call("Layers.remove", args: [obj]) }
        layer.object = build(current.state)
        return layer
    }

    override func removeLayer(entity: RasterLayerEntity<LongdoRasterLayerHandle>) async {
        if let obj = entity.layer?.object { bridge?.call("Layers.remove", args: [obj]) }
    }

    func reapply(_ handles: [LongdoRasterLayerHandle]) {}

    private func build(_ state: RasterLayerState) -> LongdoMap.LDObject? {
        guard let bridge else { return nil }
        switch state.source {
        // ラスターの `tileSize` は渡していない。Longdo の `Layer` は 256 固定で、
        // options に `tileSize` を足しても**何も変わらないことを実測で確認した**
        // （地図ズーム 13 で要求されるタイルは z=13 のまま、線の太さも 10px のまま）。
        // 結果として 512 のタイルが 256 の枠に入り、中身は半分の大きさで描かれる。
        case let .urlTemplate(template, _, minZoom, maxZoom, _, _):
            var options: [String: Any] = [
                "type": bridge.ldstatic("LayerType", with: "Custom"),
                "url": template,
                "opacity": state.opacity,
            ]
            if let minZoom, let maxZoom { options["zoomRange"] = minZoom...maxZoom }
            let obj = bridge.ldobject("Layer", with: ["", options])
            bridge.call("Layers.add", args: [obj])
            return obj
        case .tileJson, .arcGisService:
            return nil
        }
    }
}

/// Longdo raster layer controller. Diffing/state come from the core `RasterLayerController`;
/// drawing is delegated to ``LongdoRasterLayerOverlayRenderer``.
@MainActor
final class LongdoRasterLayerController: RasterLayerController<LongdoRasterLayerHandle, LongdoRasterLayerOverlayRenderer> {
    init(bridge: LongdoBridge?) {
        super.init(rasterLayerManager: RasterLayerManager<LongdoRasterLayerHandle>(), renderer: LongdoRasterLayerOverlayRenderer(bridge: bridge))
    }
}
