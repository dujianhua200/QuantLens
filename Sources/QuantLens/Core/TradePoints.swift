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
/// 来源：
/// - 日线：`TradePointEngine` 的显式买卖点（含止损/目标/R 值）
/// - 分时：来自 `IntradaySignals` 的触发
/// 旧 `markers` 转译已废弃：新引擎直接产出带止损目标的买卖点。
struct TradePoint: Identifiable, Hashable {
    let id = UUID()
    var direction: TradeDirection
    var price: Double
    var date: Date
    var reason: String
    /// 所属信号类，如“平台突破”“回踩均价”
    var kindLabel: String
    var source: TradePointSource
    var score: Double
    /// 止损 / 目标 / 盈亏比（日线引擎点才有，分时触发为空）
    var stopLoss: Double?
    var target: Double?
    var rMultiple: Double?
    /// 多族共振标记
    var isStrong: Bool = false
    /// 环境门控否决标记
    var isVetoed: Bool = false

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

    /// 从新引擎买卖点转译：保留止损/目标/R 值与强/否决标记。
    static func from(tradePointSignal p: TradePointSignal) -> TradePoint {
        TradePoint(
            direction: p.direction,
            price: p.price,
            date: p.date,
            reason: p.reason,
            kindLabel: p.kind.label,
            source: .daily,
            score: p.strength,
            stopLoss: p.stopLoss,
            target: p.target,
            rMultiple: p.rMultiple,
            isStrong: p.isStrong,
            isVetoed: p.isVetoed
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

    /// 从一次日线分析中提取买卖点记录：新引擎买卖点按时间倒序。
    /// 引擎无输出时回落到旧标记转译（保证扫描行不为空），但止损/目标为空。
    static func dailyPoints(from analysis: Analysis, limit: Int = 6) -> [TradePoint] {
        var out: [TradePoint] = []
        for p in analysis.tradePoints {
            out.append(TradePoint.from(tradePointSignal: p))
        }
        if out.isEmpty {
            var seen = Set<String>()
            for m in analysis.markers {
                let k = "\(m.kind.rawValue)-\(m.date.timeIntervalSince1970)"
                guard !seen.contains(k) else { continue }
                seen.insert(k)
                out.append(TradePoint.from(signal: m))
            }
        }
        out.sort { $0.date > $1.date }
        return Array(out.prefix(limit))
    }
}
