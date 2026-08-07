import Foundation
import MapConductorCore

/// マーカークラスタリング（`MapConductorMarkerClustering`）用のマーカーレンダラ。
///
/// android-for-longdo の `LongdoClusterMarkerRenderer.kt` の移植。
///
/// クラスタリングモジュールは ``MarkerRenderingSupport`` 経由でこのレンダラを生成し、
/// ズーム／パンに応じて算出したクラスタ／単体マーカー（``MarkerState``）を
/// onAdd / onChange / onRemove で流し込む。本実装はそれらを収集して
/// ``onMarkersChanged`` へ渡すだけの薄いアダプタで、実際の描画は既存の
/// `LongdoMarkerController`（DOM マーカー）が担う。
///
/// これにより、少数（クラスタ＋可視単体）のマーカーは通常のマーカー経路で描画され、
/// 地図追従・タップ（クラスタは拡大、単体は onClick）が既存実装のまま機能する。
///
/// `ActualMarker` は他プロバイダと同じく、このプロバイダの「ネイティブマーカー型」である
/// ``LongdoActualMarker`` を用いる。Longdo の DOM マーカーは JS 側にあり Swift 側に実体が
/// 無いため、この型は識別用のプレースホルダ。クラスタ側は
/// `MarkerClusterGroup<LongdoActualMarker>` として接続してくる。
@MainActor
final class LongdoClusterMarkerRenderer: MarkerOverlayRendererProtocol {
    typealias ActualMarker = LongdoActualMarker

    var animateStartListener: OnMarkerEventHandler?
    var animateEndListener: OnMarkerEventHandler?

    /// 収集したマーカー一覧が変化したときに呼ばれる。挿入順を保つため配列で保持する。
    ///
    /// `nil` は「クラスタリングが切断された」ことを表し、呼び出し側は通常の
    /// content 由来のマーカー描画へ戻す。空配列（クラスタ結果が 0 件）とは区別する。
    private let onMarkersChanged: ([MarkerState]?) -> Void

    private var order: [String] = []
    private var current: [String: MarkerState] = [:]

    init(onMarkersChanged: @escaping ([MarkerState]?) -> Void) {
        self.onMarkersChanged = onMarkersChanged
    }

    func onAdd(data: [MarkerOverlayAddParams]) async -> [LongdoActualMarker?] {
        for params in data { upsert(params.state) }
        return data.map { _ in LongdoActualMarker() }
    }

    func onChange(data: [MarkerOverlayChangeParams<LongdoActualMarker>]) async -> [LongdoActualMarker?] {
        for params in data { upsert(params.current.state) }
        return data.map { $0.current.marker ?? LongdoActualMarker() }
    }

    func onRemove(data: [MarkerEntity<LongdoActualMarker>]) async {
        for entity in data {
            let id = entity.state.id
            if current.removeValue(forKey: id) != nil {
                order.removeAll { $0 == id }
            }
        }
    }

    /// クラスタ側のアニメーションは扱わない（クラスタ／単体とも DOM マーカー側で描画されるため）。
    func onAnimate(entity: MarkerEntity<LongdoActualMarker>) async {}

    /// android の `onPostProcess` と同じ位置で、1 回の差分適用ごとにまとめて通知する。
    /// マーカーごとに通知するとマーカー構成全体が毎回作り直され、大量データで著しく遅くなる。
    func onPostProcess() async {
        onMarkersChanged(order.compactMap { current[$0] })
    }

    func unbind() {
        order.removeAll()
        current.removeAll()
        // 空配列ではなく nil。空配列だと「クラスタ結果が 0 件」と解釈され、
        // content 由来のマーカーが復帰しない。
        onMarkersChanged(nil)
    }

    private func upsert(_ state: MarkerState) {
        if current.updateValue(state, forKey: state.id) == nil {
            order.append(state.id)
        }
    }
}
