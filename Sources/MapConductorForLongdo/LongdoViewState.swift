import Combine
import Foundation
import MapConductorCore

/// Longdo Map view state. Holds camera position, design and controller, and forwards camera
/// operations to ``LongdoViewController``. Mirrors android-for-longdo's `LongdoViewState` and the
/// other iOS providers' `*ViewState`.
public final class LongdoViewState: MapViewState<LongdoMapDesignType> {
    private let stateId: String

    @Published private var _cameraPosition: MapCameraPosition
    @Published private var _mapDesignType: LongdoMapDesignType
    @Published private var _uiSettings: MapUISettings

    private var controller: LongdoViewController?

    /// Provider-typed holder: `map`/`mapView` are `LongdoMap`, no cast needed.
    public private(set) var mapViewHolder: LongdoMapViewHolder?

    public override var id: String { stateId }

    public override var cameraPosition: MapCameraPosition { _cameraPosition }

    public override var mapDesignType: LongdoMapDesignType {
        get { _mapDesignType }
        set {
            _mapDesignType = newValue
            controller?.setMapDesignType(newValue)
        }
    }

    public override var uiSettings: MapUISettings {
        get { _uiSettings }
        set { _uiSettings = newValue }
    }

    public init(
        id: String,
        mapDesignType: LongdoMapDesignType = LongdoDesign.Normal,
        cameraPosition: MapCameraPosition = .Default,
        uiSettings: MapUISettings = MapUISettings()
    ) {
        self.stateId = id
        self._mapDesignType = mapDesignType
        self._cameraPosition = cameraPosition
        self._uiSettings = uiSettings
        super.init()
    }

    public convenience init(
        mapDesignType: LongdoMapDesignType = LongdoDesign.Normal,
        cameraPosition: MapCameraPosition = .Default,
        uiSettings: MapUISettings = MapUISettings()
    ) {
        self.init(id: UUID().uuidString, mapDesignType: mapDesignType, cameraPosition: cameraPosition, uiSettings: uiSettings)
    }

    public override func moveCameraTo(cameraPosition: MapCameraPosition, durationMillis: Long? = 0) {
        let resolved = resolveCameraPosition(cameraPosition)
        _cameraPosition = resolved
        guard let controller = controller else { return }
        if let durationMillis, durationMillis > 0 {
            controller.animateCamera(position: resolved, duration: durationMillis)
        } else {
            controller.moveCamera(position: resolved)
        }
    }

    public override func moveCameraTo(position: GeoPoint, durationMillis: Long? = 0) {
        let updated = cameraPosition.copy(position: position)
        moveCameraTo(cameraPosition: updated, durationMillis: durationMillis)
    }

    public override func fitBounds(bounds: GeoRectBounds, padding: Int) {
        controller?.fitBounds(bounds: bounds, padding: padding)
    }

    public override func getMapViewHolder() -> AnyMapViewHolder? {
        mapViewHolder.map { AnyMapViewHolder($0) }
    }

    func setController(_ controller: LongdoViewController?) {
        self.controller = controller
        if let controller = controller {
            controller.moveCamera(position: cameraPosition)
        }
    }

    func setMapViewHolder(_ holder: LongdoMapViewHolder?) {
        mapViewHolder = holder
    }

    func updateCameraPosition(_ cameraPosition: MapCameraPosition) {
        DispatchQueue.main.async { [weak self] in
            self?._cameraPosition = cameraPosition
        }
    }

    private func resolveCameraPosition(_ target: MapCameraPosition) -> MapCameraPosition {
        let isUnspecified = target.zoom == 0.0 && target.bearing == 0.0 && target.tilt == 0.0
        if isUnspecified {
            return cameraPosition.copy(position: target.position)
        }
        return target
    }
}
