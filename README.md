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

| File | Role |
|---|---|
| `LongdoMapView.swift` | SwiftUI `UIViewRepresentable` over `LongdoMap`; coordinator = `LongdoBridge`, camera events, 3-stage move dispatcher |
| `LongdoViewState.swift` | `MapViewState` subclass (camera, design, controller) |
| `controller/LongdoViewController.swift` | Camera via `location`/`zoom`/`rotate`/`pitch`/`bound` |
| `controller/LongdoMapViewHolder.swift` | `MapViewHolderProtocol` over `LongdoMap` |
| `LongdoOverlaySupport.swift` | `LongdoBridge` protocol + geometry helpers |
| `LongdoDesign.swift` | Base layers (`NORMAL`, `GRAY`, `DARK`, `SPHERE_IMAGES`, …) |
| `LongdoOverlayBinding.swift` | Wires overlay collectors + controllers + marker controller |
| `{polyline,polygon,circle,groundimage,raster}/…` | Core overlay controllers + native Longdo renderers |
| `marker/LongdoMarkerController.swift` | Native `longdo.Marker` overlays (icon, click/drag) |

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
events. Marker tiling/clustering is not optimized (Longdo renders each marker individually).
