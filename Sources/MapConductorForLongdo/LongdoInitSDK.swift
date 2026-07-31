import Foundation

/// Global configuration for the Longdo Map API3 WebView provider.
///
/// The Android counterpart (`LongdoInitSDK`) sets `LongdoMap.API_KEY` / `LongdoMap.PACKAGE_NAME`
/// on the native WebView SDK before loading the map. On iOS there is no native Longdo SDK object -
/// the map is loaded inside a `WKWebView` from `https://api.longdo.com/map3/?key=<API_KEY>` - so the
/// only global state needed is the API key. Provide it once (e.g. from your app start-up) or pass it
/// per-view via `LongdoMapView(state:apiKey:)`.
///
/// The key can be resolved (in priority order) from:
/// 1. an explicit `apiKey` argument passed to `LongdoMapView`,
/// 2. `LongdoInitSDK.apiKey` set programmatically,
/// 3. the app's `Info.plist` under the `LONGDO_API_KEY` key.
public enum LongdoInitSDK {
    /// Info.plist key that holds the Longdo Map API key.
    public static let infoPlistKey = "LONGDO_API_KEY"

    /// Programmatically provided API key. Takes precedence over the Info.plist value.
    public static var apiKey: String?

    /// Resolves the API key to use, preferring an explicit value, then the programmatic
    /// ``apiKey``, then the Info.plist entry. Returns `nil` when none is configured.
    public static func resolveApiKey(_ explicit: String? = nil) -> String? {
        if let explicit, !explicit.isEmpty { return explicit }
        if let apiKey, !apiKey.isEmpty { return apiKey }
        if let value = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String,
           !value.isEmpty,
           !value.contains("$(") {
            return value
        }
        return nil
    }
}
