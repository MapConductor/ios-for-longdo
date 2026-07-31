import Foundation
import MapConductorCore

/// Longdo Map design (base layer). Mirrors android-for-longdo's `LongdoMapDesignTypeInterface`.
///
/// `id` uniquely identifies the design (also used for state save/restore); `layerName` is the
/// Longdo Map JS API3 base-layer name under `longdo.Layers.<NAME>` (e.g. `NORMAL` / `GRAY` / `DARK`).
public protocol LongdoMapDesignTypeProtocol: MapDesignTypeProtocol where Identifier == String {
    /// Base layer name under `longdo.Layers` (e.g. `NORMAL`, `GRAY`, `DARK`).
    var layerName: String { get }
}

public typealias LongdoMapDesignType = any LongdoMapDesignTypeProtocol

/// A Longdo Map base-layer design.
public struct LongdoDesign: LongdoMapDesignTypeProtocol, Hashable {
    public let id: String
    public let layerName: String
    public let attributionRules: [AttributionRule]

    public init(id: String, layerName: String, attributionRules: [AttributionRule] = []) {
        self.id = id
        self.layerName = layerName
        self.attributionRules = attributionRules
    }

    public func getValue() -> String { id }

    // The base layers below are those provided by Longdo Map API3 (`longdo.Layers`), matching
    // android-for-longdo's LongdoDesign entries.

    /// Standard map.
    public static let Normal = LongdoDesign(id: "Normal", layerName: "NORMAL")
    /// Simple, easy-to-read map.
    public static let Easy = LongdoDesign(id: "Easy", layerName: "EASY")
    /// Pastel-toned map.
    public static let Pastel = LongdoDesign(id: "Pastel", layerName: "PASTEL")
    /// Pastel grayscale map.
    public static let PastelGray = LongdoDesign(id: "PastelGray", layerName: "PASTEL_GRAY")
    /// High-contrast map.
    public static let Hard = LongdoDesign(id: "Hard", layerName: "HARD")
    /// Grayscale map.
    public static let Gray = LongdoDesign(id: "Gray", layerName: "GRAY")
    /// Light map.
    public static let Light = LongdoDesign(id: "Light", layerName: "LIGHT")
    /// Night (dark) map.
    public static let Night = LongdoDesign(id: "Night", layerName: "NIGHT")
    /// Dark-theme map.
    public static let Dark = LongdoDesign(id: "Dark", layerName: "DARK")
    /// Political / administrative boundary map.
    public static let Political = LongdoDesign(id: "Political", layerName: "POLITICAL")
    /// OpenStreetMap-based map.
    public static let Osm = LongdoDesign(id: "Osm", layerName: "OSM")
    /// Satellite (aerial imagery).
    public static let Satellite = LongdoDesign(id: "Satellite", layerName: "SPHERE_IMAGES")
    /// Satellite + labels (hybrid).
    public static let Hybrid = LongdoDesign(id: "Hybrid", layerName: "SPHERE_HYBRID")

    /// Every SDK-provided design (used by the design selector page).
    public static let all: [LongdoDesign] = [
        Normal, Easy, Pastel, PastelGray, Hard, Gray,
        Light, Night, Dark, Political, Osm, Satellite, Hybrid,
    ]

    /// Restores a design from a saved `id`; falls back to ``Normal`` when unknown.
    public static func fromId(_ id: String?) -> LongdoDesign {
        all.first { $0.id == id } ?? Normal
    }
}
