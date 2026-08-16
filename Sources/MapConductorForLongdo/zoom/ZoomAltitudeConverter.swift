import Foundation
import MapConductorCore

/// 統一ズーム（Google Maps 基準・256px タイル）⇄ 高度の変換。
///
/// `tilt < 0`（見上げ）の疑似表現にカメラ高度が要るために使う。入力は統一ズームで、
/// Longdo のネイティブズームとのオフセットは `LongdoViewController` 側で当てているので
/// ここでは 0。換算式はコアの ``WebMercatorZoomAltitudeConverter`` にある。
/// android-for-longdo の `zoom/ZoomAltitudeConverter` と同じ。
final class ZoomAltitudeConverter: WebMercatorZoomAltitudeConverter {
    init(zoom0Altitude: Double = AbstractZoomAltitudeConverter.defaultZoom0Altitude) {
        super.init(zoom0Altitude: zoom0Altitude, zoomOffset: 0.0)
    }
}

@inline(__always)
func longdoClamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    Swift.min(Swift.max(value, lower), upper)
}
