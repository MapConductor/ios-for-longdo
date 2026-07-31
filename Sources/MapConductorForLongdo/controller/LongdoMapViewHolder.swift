import CoreGraphics
import Foundation
import LongdoMapFramework
import MapConductorCore

/// `MapViewHolderProtocol` implementation for the official Longdo Map SDK. Both `mapView` and `map`
/// are the `LongdoMap` instance. Longdo's coordinate⇄screen conversion has no synchronous Swift API,
/// so `toScreenOffset` / `fromScreenOffset` return `nil` (parity with android-for-longdo).
public final class LongdoMapViewHolder: MapViewHolderProtocol {
    public let mapView: LongdoMap
    public let map: LongdoMap

    init(map: LongdoMap) {
        self.mapView = map
        self.map = map
    }

    public func toScreenOffset(position: GeoPointProtocol) -> CGPoint? { nil }
    public func fromScreenOffset(offset: CGPoint) async -> GeoPoint? { nil }
    public func fromScreenOffsetSync(offset: CGPoint) -> GeoPoint? { nil }
}
