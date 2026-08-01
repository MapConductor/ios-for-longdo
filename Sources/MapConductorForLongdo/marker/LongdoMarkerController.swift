import Combine
import CoreLocation
import Foundation
import LongdoMapFramework
import MapConductorCore
import UIKit

/// Renders MapConductor markers as native `longdo.Marker` overlays on `map.Overlays`. Longdo keeps
/// native markers pinned to their lon/lat as the map moves, so no screen-space projection is needed.
/// Click/drag are routed from the SDK's overlay events (matched to the nearest marker, since the
/// bridge does not expose a stable overlay id in Swift). Mirrors android-for-longdo's marker layer.
@MainActor
final class LongdoMarkerController {
    private weak var bridge: LongdoBridge?
    private var states: [String: MarkerState] = [:]
    private var objects: [String: LongdoMap.LDObject] = [:]
    private var subscriptions: [String: AnyCancellable] = [:]

    /// Geo→view projection supplied by the map-view coordinator, used for tap hit-testing.
    var projector: ((GeoPointProtocol) -> CGPoint?)?

    /// When set, drop/bounce animations run on the screen-space overlay layer shared with the
    /// other providers: the icon falls from above the map's top edge down to the marker while
    /// the native DOM marker stays hidden (mirrors android-for-longdo, where the marker layer
    /// animates the icon in screen space).
    var animationOverlay: MarkerAnimationOverlayCoordinator?

    /// Marker ids whose overlay animation is currently running (their DOM markers stay hidden).
    private var animatingIds: Set<String> = []

    /// Called whenever a marker moves during a custom drag (used to keep its info bubble attached).
    var onDragVisualUpdate: ((String) -> Void)?

    private var draggingMarkerId: String?

    init(bridge: LongdoBridge?) {
        self.bridge = bridge
    }

    /// Hit-tests a map click against the markers' on-screen icon rects and dispatches the
    /// topmost hit's click callback. Markers are rendered with `pointer-events:none`, so all
    /// taps reach the map and arrive here as regular clicks — marker detection does NOT depend
    /// on the SDK's OverlayClick (mirrors android-for-longdo's handleMarkerTap). Returns true
    /// when a marker consumed the tap.
    func handleTap(_ point: GeoPoint) -> Bool {
        guard let projector, let tapPoint = projector(point) else { return false }
        NSLog("tap point at : %@", String(point.toUrlValue()))
        guard let id = markerId(at: tapPoint, where: { $0.clickable }), let state = states[id] else { return false }
        state.onClick?(state)
        return true
    }

    // MARK: - Custom drag (long-press pickup, SDK marker dragging is never used)

    /// True when a draggable marker's icon covers the given view point.
    func hasDraggableMarker(at point: CGPoint) -> Bool {
        markerId(at: point, where: { $0.draggable }) != nil
    }

    /// Picks up the draggable marker under the given view point. Returns false when none is hit.
    func beginDrag(at point: CGPoint) -> Bool {
        guard let id = markerId(at: point, where: { $0.draggable }), let state = states[id] else { return false }
        draggingMarkerId = id
        state.onDragStart?(state)
        onDragVisualUpdate?(id)
        return true
    }

    func updateDrag(to position: GeoPoint) {
        guard let id = draggingMarkerId, let state = states[id] else { return }
        moveNativeMarker(id: id, to: position)
        state.position = position
        state.onDrag?(state)
        onDragVisualUpdate?(id)
    }

    func endDrag(at position: GeoPoint?) {
        guard let id = draggingMarkerId, let state = states[id] else {
            draggingMarkerId = nil
            return
        }
        if let position {
            moveNativeMarker(id: id, to: position)
            state.position = position
        }
        draggingMarkerId = nil
        state.onDragEnd?(state)
        onDragVisualUpdate?(id)
    }

    private func moveNativeMarker(id: String, to position: GeoPoint) {
        guard let obj = objects[id] else { return }
        _ = bridge?.objectCall(obj, method: "location", args: [position.clLocation, false])
    }

    /// Finds the marker whose icon rect (with a small slop) covers the view point; when several
    /// match, the one whose anchor is closest to the point wins.
    private func markerId(at screenPoint: CGPoint, where predicate: (MarkerState) -> Bool) -> String? {
        guard let projector else { return nil }
        var best: (id: String, distance: CGFloat)?
        for (id, state) in states where predicate(state) {
            guard let markerPoint = projector(state.position) else { continue }
            let icon = (state.icon ?? DefaultMarkerIcon()).toBitmapIcon()
            let rect = CGRect(
                x: markerPoint.x - icon.size.width * icon.anchor.x,
                y: markerPoint.y - icon.size.height * icon.anchor.y,
                width: icon.size.width,
                height: icon.size.height
            ).insetBy(dx: -6, dy: -6)
            guard rect.contains(screenPoint) else { continue }
            let dx = screenPoint.x - markerPoint.x
            let dy = screenPoint.y - markerPoint.y
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance {
                best = (id, distance)
            }
        }
        return best?.id
    }

    func sync(_ markers: [MarkerState]) {
        let newIds = Set(markers.map { $0.id })
        for id in Set(states.keys).subtracting(newIds) {
            if let obj = objects[id] { bridge?.call("Overlays.remove", args: [obj]) }
            states.removeValue(forKey: id)
            objects.removeValue(forKey: id)
            subscriptions.removeValue(forKey: id)?.cancel()
        }
        for marker in markers {
            let isNew = states[marker.id] == nil
            states[marker.id] = marker
            addOrUpdate(marker)
            if isNew { subscribe(marker) }
            maybeStartAnimation(marker)
        }
    }

    /// Starts the screen-space drop/bounce animation for a marker whose state requests one.
    /// The native DOM marker is rendered hidden while the overlay animates the icon; when the
    /// animation finishes the marker is rebuilt visible at its target. Without an overlay host
    /// the marker is simply shown at its target (no legacy geographic interpolation on Longdo).
    private func maybeStartAnimation(_ state: MarkerState) {
        guard let animation = state.getAnimation() else { return }
        guard !animatingIds.contains(state.id) else { return }
        guard let overlay = animationOverlay else {
            state.animate(nil)
            addOrUpdate(state)
            return
        }
        animatingIds.insert(state.id)
        let icon = (state.icon ?? DefaultMarkerIcon()).toBitmapIcon()
        overlay.start(MarkerAnimationOverlayEntry(
            id: state.id,
            state: state,
            icon: icon,
            animation: animation,
            duration: animation == .Bounce ? 2.0 : 0.3,
            onFinished: { [weak self] in
                guard let self else { return }
                self.animatingIds.remove(state.id)
                state.animate(nil)
                if self.states[state.id] != nil {
                    self.addOrUpdate(state)
                }
            }
        ))
    }

    /// Route an overlay event to its marker and fire the click/drag callback. Longdo delivers
    /// the clicked overlay's `LDObject` as the payload, which we match against the stored
    /// objects for an exact id; coordinate payloads (if any) fall back to nearest-marker.
    func handleOverlayEvent(event: String, result: Any?) {
        guard let (id, state) = marker(for: result) else { return }
        let lower = event.lowercased()
        // Drag payloads carry no coordinate: ask the native overlay where it is now.
        func currentCoordinate() -> CLLocationCoordinate2D? {
            if let coord = Self.location(from: result) { return coord }
            guard let obj = objects[id] else { return nil }
            return bridge?.objectCall(obj, method: "location", args: nil) as? CLLocationCoordinate2D
        }
        if lower.contains("drop") {
            if let coord = currentCoordinate() {
                state.position = GeoPoint(latitude: coord.latitude, longitude: coord.longitude, altitude: 0)
            }
            state.onDragEnd?(state)
        } else if lower.contains("drag") {
            if let coord = currentCoordinate() {
                state.position = GeoPoint(latitude: coord.latitude, longitude: coord.longitude, altitude: 0)
            }
            state.onDrag?(state)
        } else if lower.contains("click") {
            if state.clickable { state.onClick?(state) }
        }
    }

    private func marker(for result: Any?) -> (String, MarkerState)? {
        if let obj = result as? LongdoMap.LDObject,
           let id = objects.first(where: { $0.value == obj })?.key,
           let state = states[id] {
            return (id, state)
        }
        if let coord = Self.location(from: result) { return nearestMarker(to: coord) }
        return nil
    }

    /// Current state for a marker id (used by the info-bubble coordinator to resolve icons).
    func getMarkerState(for id: String) -> MarkerState? {
        states[id]
    }

    func clear() {
        for obj in objects.values { bridge?.call("Overlays.remove", args: [obj]) }
        states.removeAll()
        objects.removeAll()
        subscriptions.values.forEach { $0.cancel() }
        subscriptions.removeAll()
        animatingIds.removeAll()
    }

    private func addOrUpdate(_ marker: MarkerState) {
        guard let bridge else { return }
        if let existing = objects[marker.id] { bridge.call("Overlays.remove", args: [existing]) }
        let icon = (marker.icon ?? DefaultMarkerIcon()).toBitmapIcon()
        // The SDK ignores the icon "offset" option (both for UIImage and html icons), so the
        // anchor point never reached Longdo JS. Anchor in the HTML itself instead: a zero-size
        // wrapper makes the SDK's default anchoring degenerate to the marker location, and the
        // absolutely-positioned <img> shifts by -anchor so the anchor point lands on the
        // location. CSS width/height keep the retina bitmap at its point size.
        let width = Int(icon.size.width.rounded())
        let height = Int(icon.size.height.rounded())
        let anchorX = Int((icon.size.width * icon.anchor.x).rounded())
        let anchorY = Int((icon.size.height * icon.anchor.y).rounded())
        let base64 = icon.bitmap.pngData()?.base64EncodedString() ?? ""
        // Every marker passes touches through to the map (pointer-events:none): an interactive
        // DOM marker would swallow touches before they reach the map. Clicks are detected by
        // our own hit test in handleTap, and dragging is implemented as a custom long-press
        // gesture in the map view (the SDK's marker dragging is never used).
        // Markers with a pending or running drop/bounce animation are rendered invisible: the
        // screen-space overlay draws the falling icon and the DOM marker is rebuilt visible
        // when the animation finishes.
        let hidden = marker.getAnimation() != nil || animatingIds.contains(marker.id)
        let html = "<div style=\"width:0;height:0;position:relative;pointer-events:none;\">"
            + "<img src=\"data:image/png;base64,\(base64)\" "
            + "style=\"position:absolute;left:\(-anchorX)px;top:\(-anchorY)px;"
            + "width:\(width)px;height:\(height)px;max-width:none;display:block;"
            + "\(hidden ? "visibility:hidden;" : "")\"></div>"
        let options: [String: Any] = [
            "icon": ["html": html],
            "draggable": false,
            "clickable": marker.clickable,
            "weight": bridge.ldstatic("OverlayWeight", with: "Top"),
        ]
        let obj = bridge.ldobject("Marker", with: [marker.position.clLocation, options])
        bridge.call("Overlays.add", args: [obj])
        objects[marker.id] = obj
    }

    private func subscribe(_ marker: MarkerState) {
        subscriptions[marker.id] = marker.asFlow()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.states[marker.id] != nil else { return }
                // During a custom drag the native overlay is moved directly; rebuilding it
                // here for every position change would flicker and fight the drag.
                if self.draggingMarkerId == marker.id { return }
                self.addOrUpdate(marker)
                self.maybeStartAnimation(marker)
            }
    }

    private func nearestMarker(to coord: CLLocationCoordinate2D) -> (String, MarkerState)? {
        var best: (String, MarkerState)?
        var bestDist = Double.greatestFiniteMagnitude
        for (id, state) in states {
            let dLat = state.position.latitude - coord.latitude
            let dLon = state.position.longitude - coord.longitude
            let dist = dLat * dLat + dLon * dLon
            if dist < bestDist { bestDist = dist; best = (id, state) }
        }
        // ~500m tolerance in squared degrees (loose; overlay events already target this marker).
        return bestDist < 0.05 ? best : nil
    }

    private static func location(from result: Any?) -> CLLocationCoordinate2D? {
        if let coord = result as? CLLocationCoordinate2D { return coord }
        if let dict = result as? [String: Any] {
            let lat = (dict["lat"] as? NSNumber)?.doubleValue ?? (dict["latitude"] as? NSNumber)?.doubleValue
            let lon = (dict["lon"] as? NSNumber)?.doubleValue ?? (dict["longitude"] as? NSNumber)?.doubleValue
            if let lat, let lon { return CLLocationCoordinate2D(latitude: lat, longitude: lon) }
            if let loc = dict["location"] as? [String: Any] {
                let la = (loc["lat"] as? NSNumber)?.doubleValue
                let lo = (loc["lon"] as? NSNumber)?.doubleValue
                if let la, let lo { return CLLocationCoordinate2D(latitude: la, longitude: lo) }
            }
        }
        return nil
    }
}
