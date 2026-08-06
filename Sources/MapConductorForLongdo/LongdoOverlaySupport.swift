import CoreLocation
import Foundation
import LongdoMapFramework
import MapConductorCore

/// Thin abstraction over the Longdo Map SDK instance so the controller and overlay renderers can
/// drive it (`call` / `ldobject` / `ldstatic` / `objectCall`) without holding the `LongdoMap` view
/// directly. Implemented by the map-view coordinator.
protocol LongdoBridge: AnyObject {
    func ldobject(_ type: String, with args: [Any]) -> LongdoMap.LDObject
    func ldstatic(_ type: String, with name: String) -> LongdoMap.LDStatic
    @discardableResult func call(_ method: String, args: [Any]?) -> Any?
    @discardableResult func objectCall(_ object: LongdoMap.LDObject, method: String, args: [Any]?) -> Any?
    /// Evaluates raw JavaScript in the Longdo map's WebView. Used to add a MapLibre-GL raster
    /// source/layer directly to the underlying map (`map.Renderer`) — the marker-tile overlay,
    /// mirroring android-for-longdo which injects the same source/layer via `longdoMap.run(js)`.
    func runJavaScript(_ js: String)
}

/// Shared helpers for the Longdo overlay renderers. With the native SDK, geometry is passed as
/// `CLLocationCoordinate2D` and colors as `UIColor` directly (no CSS/JS conversion needed).
extension GeoPointProtocol {
    var clLocation: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Interpolates a path (geodesic or linear), normalizes points, splits at the antimeridian, and
/// returns each continuous segment as `CLLocationCoordinate2D` arrays.
func longdoSegments(_ points: [GeoPointProtocol], geodesic: Bool, minCount: Int) -> [[CLLocationCoordinate2D]] {
    let interpolated = (geodesic ? WGS84Geodesic.createInterpolatePoints(points) : Planar.createInterpolatePoints(points)).map { $0.normalize() }
    return splitByMeridian(interpolated, geodesic: geodesic)
        .filter { $0.count >= minCount }
        .map { seg in seg.map { $0.clLocation } }
}

/// Interpolates a single ring (no antimeridian split) to `CLLocationCoordinate2D` (used for polygon
/// holes, which Longdo draws as nil-separated additional rings).
func longdoRingCoords(_ points: [GeoPointProtocol], geodesic: Bool) -> [CLLocationCoordinate2D] {
    (geodesic ? WGS84Geodesic.createInterpolatePoints(points) : Planar.createInterpolatePoints(points)).map { $0.normalize().clLocation }
}
