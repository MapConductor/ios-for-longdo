import Combine
import Foundation
import MapConductorCore

/// Longdo Map view state.
///
/// カメラの保持と委譲、`uiSettings`、`id` はコアの ``MapViewState`` が持つ。
/// ここに残るのは **Longdo 固有のもの**だけ。
///
/// ## optimisticCameraUpdate = true にしている理由
///
/// Longdo は WebView ブリッジ越しなのでカメライベントの往復が遅い。
/// 要求直後に `cameraPosition` を読むと古い値が返ってしまうため、
/// コントローラへ委譲する**前に**要求値を保持する。
/// ネイティブ SDK のプロバイダ（MapLibre / MapTiler / Mapbox …）は既定の `false` のまま
/// ——地図が返してきた実際の値だけが state に入る。
public final class LongdoViewState: MapViewState<LongdoMapDesignType> {
    @Published private var _mapDesignType: LongdoMapDesignType

    private var longdoController: LongdoViewController?

    /// Provider-typed holder: `map`/`mapView` are `LongdoMap`, no cast needed.
    public private(set) var mapViewHolder: LongdoMapViewHolder?

    public override var mapDesignType: LongdoMapDesignType {
        get { _mapDesignType }
        set {
            _mapDesignType = newValue
            longdoController?.setMapDesignType(newValue)
        }
    }

    public init(
        id: String,
        mapDesignType: LongdoMapDesignType = LongdoDesign.Normal,
        cameraPosition: MapCameraPosition = .Default,
        uiSettings: MapUISettings = MapUISettings()
    ) {
        self._mapDesignType = mapDesignType
        super.init(
            id: id,
            initialCameraPosition: cameraPosition,
            uiSettings: uiSettings,
            optimisticCameraUpdate: true
        )
    }

    public convenience init(
        mapDesignType: LongdoMapDesignType = LongdoDesign.Normal,
        cameraPosition: MapCameraPosition = .Default,
        uiSettings: MapUISettings = MapUISettings()
    ) {
        self.init(id: UUID().uuidString, mapDesignType: mapDesignType, cameraPosition: cameraPosition, uiSettings: uiSettings)
    }

    /// アプリが `state.getMapViewHolder()?.map` で `LongdoMap` を取れる形を保つための絞り込み。
    public override func getMapViewHolder() -> AnyMapViewHolder? {
        mapViewHolder.map { AnyMapViewHolder($0) }
    }

    func setController(_ controller: LongdoViewController?) {
        longdoController = controller
        attachController(controller)
    }

    func setMapViewHolder(_ holder: LongdoMapViewHolder?) {
        mapViewHolder = holder
    }

    func updateCameraPosition(_ cameraPosition: MapCameraPosition) {
        setCameraPositionInternal(cameraPosition)
    }
}
