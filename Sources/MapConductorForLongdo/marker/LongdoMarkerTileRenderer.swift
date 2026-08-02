import CoreLocation
import Foundation
import LongdoMapFramework
import MapConductorCore
import UIKit

/// Renders large marker sets as raster tiles instead of thousands of individual DOM markers —
/// the same approach as the maplibre / maptiler providers and android-for-longdo's
/// `LongdoMarkerTileRenderer`.
///
/// The core ``MarkerTileRenderer`` draws the markers into PNG tiles served by the process-shared
/// ``LocalTileServer`` (via ``TileServerRegistry``); the tiles are added as a MapLibre-GL raster
/// source/layer directly on the underlying map, mirroring android-for-longdo's `addRasterJs`. The
/// Longdo iOS SDK's WebView keeps its map instance in a script-scoped `objectList[0]` (not a window
/// global); its `.Renderer` property is the live MapLibre-GL map, so JS injected via
/// ``LongdoBridge/runJavaScript(_:)`` can `addSource`/`addLayer` on it exactly like Android. (The
/// native `longdo.Layer` Custom type — used by ``LongdoRasterLayerOverlayRenderer`` — does not
/// render a visible tile layer here, so direct injection is required.) Because Longdo and the core
/// tile renderer share the same 256px XYZ tile grid, per-zoom marker sizing
/// (``MarkerTilingOptions/iconScaleCallback``) matches the other providers.
///
/// Draggable and animated markers are excluded here — they stay on the interactive DOM-marker path
/// in ``LongdoMarkerController`` (a raster tile cannot be dragged). Tap hit-testing against the
/// tiled markers is a geo-distance test (mirrors Android's `findMarkerAt`).
@MainActor
final class LongdoMarkerTileRenderer {
    private weak var bridge: LongdoBridge?
    private let tilingOptions: MarkerTilingOptions
    private let markerManager: MarkerManager<LongdoActualMarker>
    private var tileRenderer: MarkerTileRenderer<LongdoActualMarker>?
    private var routeId: String?
    private var cacheVersion = 0

    /// Markers currently rendered as tiles, retained for tap hit-testing.
    private(set) var markers: [MarkerState] = []
    /// Fingerprint of the last rendered set, so an unchanged content sync is a no-op (no flicker).
    private var appliedFingerprints: [MarkerFingerPrint]?
    /// The MapLibre-GL raster source/layer ids injected into `objectList[0].Renderer`, and the tile
    /// URL they were created with (so an unchanged URL isn't re-injected).
    private var sourceId: String?
    private var layerId: String?
    private var appliedTemplate: String?

    init(bridge: LongdoBridge?, tilingOptions: MarkerTilingOptions) {
        self.bridge = bridge
        self.tilingOptions = tilingOptions
        self.markerManager = MarkerManager.defaultManager(minMarkerCount: tilingOptions.minMarkerCount)
    }

    /// Re-renders the given (tileable) markers into raster tiles and (re)applies the Longdo Custom
    /// layer. An unchanged marker set is a no-op so the layer is not rebuilt on every content sync.
    func render(_ markers: [MarkerState]) {
        self.markers = markers
        let fingerprints = markers.map { $0.fingerPrint() }
        if fingerprints == appliedFingerprints, sourceId != nil { return }
        appliedFingerprints = fingerprints

        markerManager.clear()
        for state in markers {
            markerManager.registerEntity(
                MarkerEntity(marker: nil, state: state, visible: true, isRendered: true)
            )
        }
        if markerManager.allEntities().isEmpty {
            removeLayer()
            return
        }

        let renderer = ensureTileRenderer()
        // Bump the cache key so a marker change forces Longdo to re-fetch the tiles (Android's ?v=).
        cacheVersion = (cacheVersion &+ 1) & 0x7fff_ffff
        renderer.invalidate()
        guard let routeId else { return }
        let template = TileServerRegistry.get().urlTemplate(
            routeId: routeId,
            tileSize: renderer.tileSize,
            cacheKey: String(cacheVersion)
        )
        applyLayer(template: template)
    }

    func clear() {
        removeLayer()
        if let routeId { TileServerRegistry.get().unregister(routeId: routeId) }
        routeId = nil
        tileRenderer = nil
        markerManager.clear()
        markers = []
        appliedFingerprints = nil
        cacheVersion = 0
    }

    /// Geo-distance tap hit-test (mirrors Android `findMarkerAt`): the nearest clickable tiled
    /// marker within ~24px of the tap at the given native (Longdo) zoom, or nil.
    func findMarkerAt(_ tap: GeoPointProtocol, nativeZoom: Double) -> MarkerState? {
        guard !markers.isEmpty else { return nil }
        let latRad = tap.latitude * .pi / 180.0
        let metersPerPixel = Self.earthCircumferenceM * cos(latRad) / (Self.tileSize * pow(2.0, nativeZoom))
        let thresholdMeters = Self.tapThresholdPx * metersPerPixel

        var best: MarkerState?
        var bestDistance = Double.greatestFiniteMagnitude
        for marker in markers where marker.clickable {
            let dLat = (marker.position.latitude - tap.latitude) * Self.metersPerDegree
            let dLng = (marker.position.longitude - tap.longitude) * Self.metersPerDegree * cos(latRad)
            let distance = (dLat * dLat + dLng * dLng).squareRoot()
            if distance < thresholdMeters, distance < bestDistance {
                bestDistance = distance
                best = marker
            }
        }
        return best
    }

    private func ensureTileRenderer() -> MarkerTileRenderer<LongdoActualMarker> {
        if let tileRenderer { return tileRenderer }
        let gid = UUID().uuidString
        routeId = gid
        // Render retina tiles (256 * screen scale) and scale the icons to match, so tiles stay
        // crisp on high-DPI screens (parity with the maplibre provider). The Longdo Custom layer
        // displays them at its default 256pt tile size.
        let contentScale = Double(UIScreen.main.scale)
        let baseCallback = tilingOptions.iconScaleCallback
        let scaledCallback: ((MarkerState, Int) -> Double)? = { state, zoom in
            (baseCallback?(state, zoom) ?? 1.0) * contentScale
        }
        let renderer = MarkerTileRenderer<LongdoActualMarker>(
            markerManager: markerManager,
            tileSize: 256 * max(1, Int(UIScreen.main.scale)),
            cacheSizeBytes: tilingOptions.cacheSize,
            debugTileOverlay: tilingOptions.debugTileOverlay,
            iconScaleCallback: scaledCallback
        )
        TileServerRegistry.get().register(routeId: gid, provider: renderer)
        tileRenderer = renderer
        return renderer
    }

    /// Adds (or re-adds on a URL change) the marker tiles as a MapLibre-GL raster source/layer,
    /// injected onto the Longdo map's underlying renderer (`objectList[0].Renderer`) — the iOS
    /// analogue of android-for-longdo's `addRasterJs`. The layer is added on top (no `beforeId`) so
    /// the markers draw above the base map and its labels.
    private func applyLayer(template: String) {
        guard let bridge, let routeId else { return }
        if template == appliedTemplate, sourceId != nil { return }
        removeLayer()
        let srcId = "mcrs_marker-tile-\(routeId)"
        let lyrId = "mcrl_marker-tile-\(routeId)"
        // The MapLibre raster source `tileSize` is the LOGICAL tile size (256 for the standard XYZ
        // grid), independent of the tiles' pixel resolution. The renderer draws retina (256*scale)
        // px PNGs and MapLibre displays them crisply at 256pt — declaring the pixel size here would
        // give MapLibre a wrong (fractional-zoom) tile grid and nothing would render.
        let sourceSpec = Self.jsonString([
            "type": "raster",
            "tiles": [template],
            "tileSize": 256,
            "maxzoom": 22,
            "scheme": "xyz",
        ])
        let layerSpec = Self.jsonString([
            "id": lyrId,
            "type": "raster",
            "source": srcId,
            "paint": ["raster-opacity": 1.0],
            "layout": ["visibility": "visible"],
        ])
        // Reach the live MapLibre map via the Longdo SDK's script-scoped map instance
        // (objectList[0].Renderer). It may not be ready the instant the first marker batch arrives,
        // so retry a few times. MapLibre's inline-tiles source finishes loading on the next animation
        // frame, so triggerRepaint() kicks the render loop; a short bounded fallback completes the
        // load manually if the WebView starves requestAnimationFrame while the map is idle (the
        // source spec is inline, so this is a synchronous, network-free completion).
        let js = """
        (function(){var tries=0;
          function ensureLoaded(m){
            var s=m.getSource('\(srcId)'); if(!s) return;
            var checks=0, iv=setInterval(function(){
              var src=m.getSource('\(srcId)');
              if(!src||src._loaded||checks++>20){clearInterval(iv);return;}
              if(src._options&&src._options.tiles){
                try{
                  src.tiles=src._options.tiles.slice(); src.minzoom=src._options.minzoom||0;
                  src.maxzoom=(src._options.maxzoom==null?22:src._options.maxzoom);
                  src.tileSize=src._options.tileSize||256; src._loaded=true;
                  if(src._tileJSONRequest&&src._tileJSONRequest.cancel)src._tileJSONRequest.cancel();
                  src._tileJSONRequest=null;
                  src.fire(new maplibregl.Event('data',{dataType:'source',sourceDataType:'metadata',sourceId:'\(srcId)'}));
                }catch(e){}
              }
              m.triggerRepaint();
            },100);
          }
          function apply(){
            try{
              var mm=(typeof objectList!=='undefined')?objectList[0]:null;
              var m=mm?mm.Renderer:null;
              if(!m||typeof m.addSource!=='function'){ if(tries++<40)setTimeout(apply,150); return; }
              if(!m.getSource('\(srcId)'))m.addSource('\(srcId)',\(sourceSpec));
              if(!m.getLayer('\(lyrId)'))m.addLayer(\(layerSpec));
              m.triggerRepaint();
              ensureLoaded(m);
            }catch(e){ if(tries++<40)setTimeout(apply,150); }
          }
          apply();
        })()
        """
        bridge.runJavaScript(js)
        sourceId = srcId
        layerId = lyrId
        appliedTemplate = template
    }

    private func removeLayer() {
        guard let bridge, let srcId = sourceId, let lyrId = layerId else { return }
        let js = "(function(){try{var mm=(typeof objectList!=='undefined')?objectList[0]:null;"
            + "var m=mm?mm.Renderer:null; if(!m) return;"
            + "if(m.getLayer('\(lyrId)'))m.removeLayer('\(lyrId)');"
            + "if(m.getSource('\(srcId)'))m.removeSource('\(srcId)');}catch(e){}})()"
        bridge.runJavaScript(js)
        sourceId = nil
        layerId = nil
        appliedTemplate = nil
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private static let tileSize = 256.0
    private static let earthCircumferenceM = 40_075_016.686
    private static let metersPerDegree = 111_320.0
    private static let tapThresholdPx = 24.0
}
