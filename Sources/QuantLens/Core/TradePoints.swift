import Foundation

// MARK: - 买卖点记录

/// 买卖方向：买点 / 卖点。
enum TradeDirection: String, Hashable {
    case buy, sell

    var label: String {
        switch self {
        case .buy: return "买点"
        case .sell: return "卖点"
        }
    }

    var shortLabel: String {
        switch self {
        case .buy: return "买"
        case .sell: return "卖"
        }
    }
}

/// 买卖点来源：日线信号引擎，或分时触发引擎。
enum TradePointSource: String, Hashable {
    case daily, intraday

    var label: String {
        switch self {
        case .daily: return "日线"
        case .intraday: return "分时"
        }
    }
}

/// 一条显性的买卖点记录：价格、触发时间、依据、所属信号类。
///
/// 这是对已有信号的“显性化转译”，不产生新口径：
/// - 日线：来自 `SignalEngine.analyze` 的 `markers`（图上三角标记同源）与当前 `signals`
/// - 分时：来自 `IntradaySignals` 的触发
/// K 线图上的标记继续复用已有 `markers` 机制，本记录只用于列表与扫描结果展示。
struct TradePoint: Identifiable, Hashable {
    let id = UUID()
    var direction: TradeDirection
    var price: Double
    var date: Date
    var reason: String
    /// 所属信号类，如“买入机会”“主力撤退”“回踩均价”
    var kindLabel: String
    var source: TradePointSource
    var score: Double

    /// 从日线信号转译：买入/进场 → 买点，风险/撤退 → 卖点。
    static func from(signal: TradingSignal) -> TradePoint {
        let direction: TradeDirection =
            (signal.kind == .buy || signal.kind == .accumulate) ? .buy : .sell
        return TradePoint(
            direction: direction,
            price: signal.price,
            date: signal.date,
            reason: signal.reasons.first ?? signal.title,
            kindLabel: signal.kind.label,
            source: .daily,
            score: signal.score
        )
    }

    /// 从分时触发转译。
    static func from(trigger: IntradayTrigger) -> TradePoint {
        TradePoint(
            direction: trigger.direction,
            price: trigger.price,
            date: trigger.time,
            reason: trigger.reason,
            kindLabel: trigger.kind.label,
            source: .intraday,
            score: trigger.strength
        )
    }

    /// 从一次日线分析中提取买卖点记录：历史标记 + 当前信号，去重后按时间倒序。
    /// 去重键为“信号类 + 触发时间”，同一根 K 线上的同一类信号只保留一条（优先保留标记）。
    static func dailyPoints(from analysis: Analysis, limit: Int = 6) -> [TradePoint] {
        var seen = Set<String>()
        var out: [TradePoint] = []

        func key(kind: SignalKind, date: Date) -> String {
            "\(kind.rawValue)-\(date.timeIntervalSince1970)"
        }

        for m in analysis.markers {
            let k = key(kind: m.kind, date: m.date)
            guard !seen.contains(k) else { continue }
            seen.insert(k)
            out.append(TradePoint.from(signal: m))
        }
        for s in analysis.signals {
            let k = key(kind: s.kind, date: s.date)
            guard !seen.contains(k) else { continue }
            seen.insert(k)
            out.append(TradePoint.from(signal: s))
        }

        out.sort { $0.date > $1.date }
        return Array(out.prefix(limit))
    }
}
