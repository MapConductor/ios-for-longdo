# MapConductorForLongdo

Longdo Map provider for MapConductor (iOS), the counterpart of `android-for-longdo`.

## Architecture

Built on the **official Longdo Map iOS SDK — Longdo Map Framework 4.x** (`LongdoMapFramework`,
`github.com/MetamediaTechnology/longdo-map-ios-framework`, pinned `from: 4.1.0`, resolves 4.1.4).
The SDK exposes a native Swift bridge over Longdo Map JS API3:

- `map = LongdoMap()`, `map.apiKey = "…"`, `map.options = LongdoMap.Option()`, `map.render()`
- `map.call(method:args:)` — invoke map methods (`location`, `zoom`, `rotate`, `pitch`, `bound`,
  `Layers.setBase`, `Overlays.add/remove/clear`, `Event.bind`, …)
- `map.ldobject(_:with:)` / `map.ldstatic(_:with:)` / `map.objectCall(ldobject:method:args:)` —
  create/drive native overlay objects (`Marker`, `Polyline`, `Polygon`, `Circle`, `Rectangle`, `Layer`)

MapConductor wraps this behind a `LongdoBridge` protocol so the controller and overlay renderers
drive the SDK without holding the view.

Underneath, the SDK is a `WKWebView` hosting Longdo Map JS API3, whose map instance lives in a
script-scoped `objectList[0]` (not a window global). That instance's `.Renderer` property is a live
MapLibre-GL map, so `LongdoBridge.runJavaScript(_:)` can `addSource`/`addLayer` on it directly —
which is how the marker tile layer is injected, mirroring android-for-longdo's `addRasterJs`.

| File | Role |
|---|---|
| `LongdoMapView.swift` | SwiftUI `UIViewRepresentable` over `LongdoMap`; coordinator = `LongdoBridge`, camera events, 3-stage move dispatcher |
| `LongdoViewState.swift` | `MapViewState` subclass (camera, design, controller) |
| `LongdoInitSDK.swift` | API key resolution: explicit argument → static property → Info.plist |
| `controller/LongdoViewController.swift` | Camera via `location`/`zoom`/`rotate`/`pitch`/`bound` |
| `controller/LongdoMapViewHolder.swift` | `MapViewHolderProtocol` over `LongdoMap` |
| `LongdoOverlaySupport.swift` | `LongdoBridge` protocol + geometry helpers |
| `LongdoDesign.swift` | Base layers (`NORMAL`, `GRAY`, `DARK`, `SPHERE_IMAGES`, …) |
| `LongdoOverlayBinding.swift` | Wires overlay collectors + controllers + marker controller |
| `LongdoTypeAlias.swift` | `LongdoActualMarker` — phantom type satisfying `MarkerClusterGroup<ActualMarker>` |
| `zoom/ZoomAltitudeConverter.swift` | Unified zoom ↔ camera altitude, for the `tilt < 0` looking-up view |
| `{polyline,polygon,circle,groundimage,raster}/…` | Core overlay controllers + native Longdo renderers |
| `marker/LongdoMarkerController.swift` | Native `longdo.Marker` overlays (icon, click/drag) |
| `marker/LongdoMarkerTileRenderer.swift` | Large marker sets as raster tiles injected onto the GL renderer |
| `marker/LongdoClusterMarkerRenderer.swift` | `MapConductorMarkerClustering` adapter feeding `LongdoMarkerController` |

## Setup

The SDK is SwiftPackage-only (binary XCFramework + Swifter). Provide the API key (any one of):

```swift
LongdoInitSDK.apiKey = "YOUR_LONGDO_API_KEY"
// or per-view:  LongdoMapView(state: state, apiKey: "…") { … }
// or add LONGDO_API_KEY to Info.plist
```

```swift
import MapConductorForLongdo

struct Demo: View {
    @StateObject private var state = LongdoViewState(
        mapDesignType: LongdoDesign.Normal,
        cameraPosition: MapCameraPosition(position: GeoPoint(latitude: 13.7563, longitude: 100.5018), zoom: 12)
    )
    var body: some View {
        LongdoMapView(state: state) {
            Marker(position: GeoPoint(latitude: 13.7563, longitude: 100.5018), icon: DefaultMarkerIcon(label: "A"))
            Circle(center: GeoPoint(latitude: 13.7563, longitude: 100.5018), radiusMeters: 1500)
        }
    }
}
```

## Supported overlays

- **Marker** → native `longdo.Marker` (custom icon; click/drag via overlay events)
- **Polyline** → native `longdo.Polyline`
- **Polygon** → native `longdo.Polygon` (holes via nil-separated rings)
- **Circle** → geodesic ring drawn as `longdo.Polygon` (Longdo's `Circle` radius unit is ambiguous)
- **GroundImage** → native `longdo.Rectangle` with `texture`
- **RasterLayer** → native `longdo.Layer` (Custom tile layer; `UrlTemplate` sources)

Colors are passed to the SDK as `UIColor` and geometry as `CLLocationCoordinate2D` directly. Vector
overlay clicks are hit-tested by the core managers; marker click/drag come from the SDK's overlay
events.

## Marker rendering paths

Longdo's own markers are DOM overlays, so rendering thousands of them individually does not scale.
Three paths are available, matching android-for-longdo:

- **Direct** — `LongdoMarkerController` creates one native `longdo.Marker` per marker. Default.
- **Tiled** — `LongdoMarkerTileRenderer` draws the whole set into PNG tiles served by the core's
  process-shared `LocalTileServer`, then injects them as a MapLibre-GL raster source/layer via
  `LongdoBridge.runJavaScript(_:)`. Direct injection is required because the native `longdo.Layer`
  Custom type (used by the raster-layer renderer) does not render a visible tile layer here.
- **Clustered** — `LongdoClusterMarkerRenderer` adapts `MapConductorMarkerClustering`: the module
  computes clusters/singles per zoom and this thin adapter forwards them to `LongdoMarkerController`,
  so map tracking and taps (cluster → zoom in, single → `onClick`) keep working unchanged.
