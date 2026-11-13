import Foundation
import LongdoMapFramework
@_spi(MapConductorDriver) import MapConductorCore

/// Handle to a Longdo raster layer: a native `longdo.Layer` (custom tile layer) added via `Layers.add`.
final class LongdoRasterLayerHandle {
    var object: LongdoMap.LDObject?
    /// Where the layer stacks (``OverlayStacking/rasterKey(stateId:zIndex:)``).
    var key: OverlayStackKey
    /// Order of creation, to keep layers with the same key in the order they came.
    let seq: Int
    init(object: LongdoMap.LDObject?, key: OverlayStackKey, seq: Int) {
        self.object = object
        self.key = key
        self.seq = seq
    }
}

/// Renders raster layers as native `longdo.Layer` custom tile layers. `UrlTemplate` sources map to
/// a Custom layer (`{z}/{x}/{y}` URL); `TileJson`/`ArcGisService` are not natively supported here.
@MainActor
final class LongdoRasterLayerOverlayRenderer: AbstractRasterLayerOverlayRenderer<LongdoRasterLayerHandle> {
    private weak var bridge: LongdoBridge?
    /// Every layer currently on the map, for ``reattachAll()``.
    private var live: [ObjectIdentifier: LongdoRasterLayerHandle] = [:]
    private var nextSeq = 0

    init(bridge: LongdoBridge?) {
        self.bridge = bridge
        super.init()
    }

    override func createLayer(state: RasterLayerState) async -> LongdoRasterLayerHandle? {
        RasterHeaderRuleSet.warnUnsupported(provider: "Longdo", state: state)
        let key = OverlayStacking.rasterKey(stateId: state.id, zIndex: state.zIndex)
        let handle = LongdoRasterLayerHandle(object: build(state), key: key, seq: nextSeq)
        nextSeq += 1
        live[ObjectIdentifier(handle)] = handle
        restack()
        return handle
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
        layer.key = OverlayStacking.rasterKey(stateId: current.state.id, zIndex: current.state.zIndex)
        restack()
        return layer
    }

    override func removeLayer(entity: RasterLayerEntity<LongdoRasterLayerHandle>) async {
        if let obj = entity.layer?.object { bridge?.call("Layers.remove", args: [obj]) }
        if let layer = entity.layer { live[ObjectIdentifier(layer)] = nil }
    }

    func reapply(_ handles: [LongdoRasterLayerHandle]) {}

    /// Puts every layer back on top after the base layer was switched.
    ///
    /// `Layers.setBase` leaves the layers in place but they stop showing until
    /// the next interaction (measured: blank for 10 s, back after a pinch).
    /// Removing and adding them again is what the next interaction does.
    func reattachAll() { readdInStackOrder() }

    /// Puts every raster layer back in stacking order, bottom first.
    ///
    /// Longdo stacks its `Layer`s in no order MapConductor controls: on the
    /// stacking check the polygon tiles (created first) were drawn over the
    /// polyline tiles (created after them), so the roads disappeared under the
    /// squares. Taking every layer off and adding it again, bottom first, once
    /// the new one is on the map, puts them right (measured on an iPad: road
    /// pixels unchanged under the polygon tiles 11 % -> 100 %).
    private func restack() {
        if live.count > 1 { readdInStackOrder() }
    }

    private func readdInStackOrder() {
        guard let bridge else { return }
        for handle in stackOrder(live.values) {
            guard let obj = handle.object else { continue }
            bridge.call("Layers.remove", args: [obj])
            bridge.call("Layers.add", args: [obj])
        }
    }

    private func stackOrder<S: Sequence>(_ handles: S) -> [LongdoRasterLayerHandle] where S.Element == LongdoRasterLayerHandle {
        handles.sorted(by: Self.isBelow)
    }

    private static func isBelow(_ a: LongdoRasterLayerHandle, _ b: LongdoRasterLayerHandle) -> Bool {
        if a.key != b.key { return a.key < b.key }
        return a.seq < b.seq
    }

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

    /// See ``LongdoRasterLayerOverlayRenderer/reattachAll()``.
    func reattachAll() { renderer.reattachAll() }
}
