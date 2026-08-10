import Combine
import CoreGraphics
import CoreLocation
import Foundation
import LongdoMapFramework
import MapConductorCore
import Swift
import SwiftUI
import UIKit
import _Concurrency
import _StringProcessing
import _SwiftConcurrencyShims
public protocol LongdoMapDesignTypeProtocol : MapConductorCore.MapDesignTypeProtocol where Self.Identifier == Swift.String {
  var layerName: Swift.String { get }
}
public typealias LongdoMapDesignType = any MapConductorForLongdo.LongdoMapDesignTypeProtocol
public struct LongdoDesign : MapConductorForLongdo.LongdoMapDesignTypeProtocol, Swift.Hashable {
  public let id: Swift.String
  public let layerName: Swift.String
  public let attributionRules: [MapConductorCore.AttributionRule]
  public init(id: Swift.String, layerName: Swift.String, attributionRules: [MapConductorCore.AttributionRule] = [])
  public func getValue() -> Swift.String
  public static let Normal: MapConductorForLongdo.LongdoDesign
  public static let Easy: MapConductorForLongdo.LongdoDesign
  public static let Pastel: MapConductorForLongdo.LongdoDesign
  public static let PastelGray: MapConductorForLongdo.LongdoDesign
  public static let Hard: MapConductorForLongdo.LongdoDesign
  public static let Gray: MapConductorForLongdo.LongdoDesign
  public static let Light: MapConductorForLongdo.LongdoDesign
  public static let Night: MapConductorForLongdo.LongdoDesign
  public static let Dark: MapConductorForLongdo.LongdoDesign
  public static let Political: MapConductorForLongdo.LongdoDesign
  public static let Osm: MapConductorForLongdo.LongdoDesign
  public static let Satellite: MapConductorForLongdo.LongdoDesign
  public static let Hybrid: MapConductorForLongdo.LongdoDesign
  public static let all: [MapConductorForLongdo.LongdoDesign]
  public static func fromId(_ id: Swift.String?) -> MapConductorForLongdo.LongdoDesign
  public static func == (a: MapConductorForLongdo.LongdoDesign, b: MapConductorForLongdo.LongdoDesign) -> Swift.Bool
  public typealias Identifier = Swift.String
  public func hash(into hasher: inout Swift.Hasher)
  public var hashValue: Swift.Int {
    get
  }
}
public enum LongdoInitSDK {
  public static let infoPlistKey: Swift.String
  public static var apiKey: Swift.String?
  public static func resolveApiKey(_ explicit: Swift.String? = nil) -> Swift.String?
}
@_Concurrency.MainActor @preconcurrency public struct LongdoMapView : SwiftUICore.View {
  @_Concurrency.MainActor @preconcurrency public init(state: MapConductorForLongdo.LongdoViewState, apiKey: Swift.String? = nil, cameraRestriction: MapConductorCore.CameraRestriction? = nil, onMapLoaded: MapConductorCore.OnMapLoadedHandler<MapConductorForLongdo.LongdoViewState>? = nil, onMapClick: MapConductorCore.OnMapEventHandler? = nil, onMapLongClick: MapConductorCore.OnMapEventHandler? = nil, onCameraMoveStart: MapConductorCore.OnCameraMoveHandler? = nil, onCameraMove: MapConductorCore.OnCameraMoveHandler? = nil, onCameraMoveEnd: MapConductorCore.OnCameraMoveHandler? = nil, sdkInitialize: (() -> Swift.Void)? = nil, @MapConductorCore.MapViewContentBuilder content: @escaping () -> MapConductorCore.MapViewContent = { MapViewContent() })
  @_Concurrency.MainActor @preconcurrency public var body: some SwiftUICore.View {
    get
  }
  public typealias Body = @_opaqueReturnTypeOf("$s21MapConductorForLongdo0dA4ViewV4bodyQrvp", 0) __
}
@_hasMissingDesignatedInitializers final public class LongdoActualMarker {
  @objc deinit
}
final public class LongdoViewState : MapConductorCore.MapViewState<MapConductorForLongdo.LongdoMapDesignType> {
  final public var mapViewHolder: MapConductorForLongdo.LongdoMapViewHolder? {
    get
  }
  override final public var id: Swift.String {
    get
  }
  override final public var cameraPosition: MapConductorCore.MapCameraPosition {
    get
  }
  override final public var mapDesignType: MapConductorForLongdo.LongdoMapDesignType {
    get
    set
  }
  override final public var uiSettings: MapConductorCore.MapUISettings {
    get
    set
  }
  public init(id: Swift.String, mapDesignType: MapConductorForLongdo.LongdoMapDesignType = LongdoDesign.Normal, cameraPosition: MapConductorCore.MapCameraPosition = .Default, uiSettings: MapConductorCore.MapUISettings = MapUISettings())
  convenience public init(mapDesignType: MapConductorForLongdo.LongdoMapDesignType = LongdoDesign.Normal, cameraPosition: MapConductorCore.MapCameraPosition = .Default, uiSettings: MapConductorCore.MapUISettings = MapUISettings())
  override final public func moveCameraTo(cameraPosition: MapConductorCore.MapCameraPosition, durationMillis: MapConductorCore.Long? = 0)
  override final public func moveCameraTo(position: MapConductorCore.GeoPoint, durationMillis: MapConductorCore.Long? = 0)
  override final public func fitBounds(bounds: MapConductorCore.GeoRectBounds, padding: Swift.Int)
  override final public func getMapViewHolder() -> MapConductorCore.AnyMapViewHolder?
  @objc deinit
}
@_hasMissingDesignatedInitializers final public class LongdoMapViewHolder : MapConductorCore.MapViewHolderProtocol {
  final public let mapView: LongdoMapFramework.LongdoMap
  final public let map: LongdoMapFramework.LongdoMap
  final public func toScreenOffset(position: any MapConductorCore.GeoPointProtocol) -> CoreFoundation.CGPoint?
  final public func fromScreenOffset(offset: CoreFoundation.CGPoint) async -> MapConductorCore.GeoPoint?
  final public func fromScreenOffsetSync(offset: CoreFoundation.CGPoint) -> MapConductorCore.GeoPoint?
  public typealias ActualMap = LongdoMapFramework.LongdoMap
  public typealias ActualMapView = LongdoMapFramework.LongdoMap
  @objc deinit
}
extension MapConductorForLongdo.LongdoMapView : Swift.Sendable {}
