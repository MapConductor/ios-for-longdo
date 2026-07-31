import Foundation

/// Phantom marker type used to select the Longdo marker-cluster rendering path, mirroring the
/// other providers' `*ActualMarker` aliases (e.g. `MapTilerActualMarker = MLNPointFeature`).
///
/// Longdo Map is WebView based and renders markers as screen-space overlays projected from the JS
/// map, so unlike the GL providers there is no native vendor feature class to alias. This
/// lightweight stand-in satisfies the `MarkerClusterGroup<ActualMarker>` generic parameter.
public final class LongdoActualMarker {}
