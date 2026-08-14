import Combine
import CoreLocation
import Foundation
import LongdoMapFramework
import MapConductorCore
import SwiftUI
import UIKit

/// SwiftUI view that displays a Longdo Map using the official Longdo Map iOS SDK (`LongdoMap`,
/// Framework 4.x). Same argument shape as the other providers' `*MapView`, so the sample app's type
/// dispatch can use it interchangeably. Mirrors android-for-longdo's `LongdoMapView`.
public struct LongdoMapView: View {
    @ObservedObject private var state: LongdoViewState

    private let apiKey: String?
    private let handlers: MapViewHandlers<LongdoViewState>
    private let cameraRestriction: CameraRestriction?
    private let content: () -> MapViewContent

    public init(
        state: LongdoViewState,
        apiKey: String? = nil,
        cameraRestriction: CameraRestriction? = nil,
        onMapLoaded: OnMapLoadedHandler<LongdoViewState>? = nil,
        onMapClick: OnMapEventHandler? = nil,
        onMapLongClick: OnMapEventHandler? = nil,
        onCameraMoveStart: OnCameraMoveHandler? = nil,
        onCameraMove: OnCameraMoveHandler? = nil,
        onCameraMoveEnd: OnCameraMoveHandler? = nil,
        sdkInitialize: (() -> Void)? = nil,
        @MapViewContentBuilder content: @escaping () -> MapViewContent = { MapViewContent() }
    ) {
        self.state = state
        self.apiKey = apiKey
        self.cameraRestriction = cameraRestriction
        self.handlers = MapViewHandlers(
            onMapLoaded: onMapLoaded,
            onMapClick: onMapClick,
            onMapLongClick: onMapLongClick,
            onCameraMoveStart: onCameraMoveStart,
            onCameraMove: onCameraMove,
            onCameraMoveEnd: onCameraMoveEnd,
            sdkInitialize: sdkInitialize
        )
        self.content = content
    }

    public var body: some View {
        // The provider's registry is in scope only while content is being assembled —
        // the same window in which Compose provides `LocalMapServiceRegistry` around the
        // content lambda. Bracketing the pass lets a removed plugin be noticed.
        let support = state.serviceRegistry.get(MarkerRenderingSupportKey.self)
        support?.beginContentPass()
        let mapContent = MapServiceRegistryScope.with(state.serviceRegistry) { content() }
        support?.endContentPass()
        return MapViewBase(
            attributionRules: state.mapDesignType.attributionRules,
            camera: state.cameraPosition,
            content: mapContent
        ) {
            LongdoMapViewRepresentable(
                state: state,
                cameraRestriction: cameraRestriction,
                apiKey: apiKey,
                handlers: handlers,
                content: mapContent
            )
        }
    }
}

private struct LongdoMapViewRepresentable: UIViewRepresentable {
    @ObservedObject var state: LongdoViewState
    let cameraRestriction: CameraRestriction?

    let apiKey: String?
    let handlers: MapViewHandlers<LongdoViewState>
    let content: MapViewContent

    func makeCoordinator() -> LongdoMapHost {
        LongdoMapHost(state: state, handlers: handlers)
    }

    func makeUIView(context: Context) -> LongdoMap {
        let map = context.coordinator.makeMap(apiKey: apiKey)
        context.coordinator.updateContent(content)
        if let sdkInitialize = handlers.sdkInitialize {
            LongdoMapHost.runOnce(sdkInitialize)
        }
        return map
    }

    func updateUIView(_ uiView: LongdoMap, context: Context) {
        // 制限値が変わったときだけ再適用する。
        context.coordinator.applyCameraRestriction(cameraRestriction)
        context.coordinator.updateGestures(state.uiSettings)
        context.coordinator.updateContent(content)
    }

    static func dismantleUIView(_ uiView: LongdoMap, coordinator: LongdoMapHost) {
        coordinator.unbind()
    }

}

/// Synthesizes the shared move-start / move / move-end 3-stage callbacks from Longdo's continuous
/// camera notifications, using a quiet-period timer for move-end. Mirrors android-for-longdo's
/// `LongdoCameraMoveDispatcher`.
@MainActor
final class LongdoCameraMoveDispatcher {
    private var moving = false
    private var endWorkItem: DispatchWorkItem?
    private let quietInterval: TimeInterval = 0.18

    func dispatch(
        position: MapCameraPosition,
        onStart: @escaping (MapCameraPosition) -> Void,
        onMove: @escaping (MapCameraPosition) -> Void,
        onEnd: @escaping (MapCameraPosition) -> Void
    ) {
        if !moving { moving = true; onStart(position) }
        onMove(position)
        endWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.moving = false; onEnd(position) }
        endWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + quietInterval, execute: work)
    }

    func cancel() {
        endWorkItem?.cancel()
        endWorkItem = nil
        moving = false
    }
}

