import Foundation
import MapConductorCore

/// Unified zoom (Google Maps based) ↔ physical camera altitude converter.
///
/// Needed for the pseudo-representation of `tilt < 0` (looking-up view), which requires a camera
/// altitude. Uses the same physical model as the Google Maps / MapLibre providers (the input zoom
/// is the unified Google zoom; the Longdo native-zoom offset is applied in `LongdoViewController`).
/// Mirrors android-for-longdo's `zoom/ZoomAltitudeConverter`.
final class ZoomAltitudeConverter: ZoomAltitudeConverterProtocol {
    let zoom0Altitude: Double

    private let minZoomLevel: Double = 0.0
    private let maxZoomLevel: Double = 22.0
    private let minAltitude: Double = 100.0
    private let maxAltitude: Double = 50_000_000.0
    private let minCosLat: Double = 0.01
    private let minCosTilt: Double = 0.05

    init(zoom0Altitude: Double = 171_319_879.0) {
        self.zoom0Altitude = zoom0Altitude
    }

    private func cosLatitudeFactor(_ latitudeDeg: Double) -> Double {
        let clampedLat = longdoClamp(latitudeDeg, -85.0, 85.0)
        return max(minCosLat, abs(cos(clampedLat * .pi / 180.0)))
    }

    private func cosTiltFactor(_ tiltDeg: Double) -> Double {
        let clampedTilt = longdoClamp(tiltDeg, 0.0, 90.0)
        return max(minCosTilt, cos(clampedTilt * .pi / 180.0))
    }

    func zoomLevelToAltitude(zoomLevel: Double, latitude: Double, tilt: Double) -> Double {
        let clampedZoom = longdoClamp(zoomLevel, minZoomLevel, maxZoomLevel)
        let cosLat = cosLatitudeFactor(latitude)
        let cosTilt = cosTiltFactor(tilt)
        let distance = (zoom0Altitude * cosLat) / pow(2.0, clampedZoom)
        let altitude = distance * cosTilt
        return longdoClamp(altitude, minAltitude, maxAltitude)
    }

    func altitudeToZoomLevel(altitude: Double, latitude: Double, tilt: Double) -> Double {
        let clampedAltitude = longdoClamp(altitude, minAltitude, maxAltitude)
        let cosLat = cosLatitudeFactor(latitude)
        let cosTilt = cosTiltFactor(tilt)
        let distance = clampedAltitude / cosTilt
        let zoomLevel = log2((zoom0Altitude * cosLat) / distance)
        return longdoClamp(zoomLevel, minZoomLevel, maxZoomLevel)
    }
}

@inline(__always)
func longdoClamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    Swift.min(Swift.max(value, lower), upper)
}
