import Foundation

// MARK: - 情绪标签

/// 信号背后的主导心理。恐惧类信号多为“别人恐惧时的承接观察”，
/// 贪婪类信号多为“众人贪婪时的兑现警示”，标签只描述心理机制，不构成操作建议。
enum SentimentTag: String, Hashable {
    case fear = "恐惧"
    case greed = "贪婪"
    case neutral = "中性"
}

// MARK: - 恐惧 / 贪婪日线信号

enum FearSignalKind: String, Hashable, CaseIterable {
    case panicCapitulation   // 恐慌割肉后企稳
    case fakeBreakdown       // 假破位诱空
    case iceFirstYang        // 冰点首根放量阳
    case fearExhaustion      // 恐惧衰竭
    case highStall           // 高位放量滞涨
    case blowoffTop          // 加速赶顶
    case limitUpOpenHuge     // 涨停开板巨量

    var label: String {
        switch self {
        case .panicCapitulation: return "恐慌企稳"
        case .fakeBreakdown: return "假破位诱空"
        case .iceFirstYang: return "冰点首阳"
        case .fearExhaustion: return "恐惧衰竭"
        case .highStall: return "高位滞涨"
        case .blowoffTop: return "加速赶顶"
        case .limitUpOpenHuge: return "涨停开板"
        }
    }

    /// 榜单窄列用的两字简称
    var shortLabel: String {
        switch self {
        case .panicCapitulation: return "企稳"
        case .fakeBreakdown: return "诱空"
        case .iceFirstYang: return "首阳"
        case .fearExhaustion: return "衰竭"
        case .highStall: return "滞涨"
        case .blowoffTop: return "赶顶"
        case .limitUpOpenHuge: return "开板"
        }
    }

    var sentiment: SentimentTag {
        switch self {
        case .panicCapitulation, .fakeBreakdown, .iceFirstYang, .fearExhaustion:
            return .fear
        case .highStall, .blowoffTop, .limitUpOpenHuge:
            return .greed
        }
    }

    var direction: TradeDirection {
        switch self {
        case .panicCapitulation, .fakeBreakdown, .iceFirstYang, .fearExhaustion:
            return .buy
        case .highStall, .blowoffTop, .limitUpOpenHuge:
            return .sell
        }
    }
}

/// 一条恐惧/贪婪日线信号：强度分 + 点明心理机制的理由。
struct FearSignal: Identifiable, Hashable {
    let id = UUID()
    var kind: FearSignalKind
    var score: Double            // 0~100，相对强度，不是概率
    var reason: String
    var price: Double
    var date: Date

    var direction: TradeDirection { kind.direction }
    var sentiment: SentimentTag { kind.sentiment }
}

// MARK: - 恐惧 / 贪婪信号引擎

/// 日线级别的情绪信号：把“恐惧宣泄—衰竭—修复”与“贪婪亢奋—兑现”
/// 两条心理链条写成可检验的量价条件。
///
/// 与 `SignalEngine` 四类信号的关系：独立计算、独立展示，不改动四类信号分数，
/// 由 `Analysis.fearSignals` 与 `ScanResult.fearSignals` 承载，供机会榜与信号面板展示。
/// 所有条件只用 `MarketContext` 已有字段（K 线 / 指标 / 支撑压力 / 量能）。
enum FearSignals {

    static func evaluate(_ ctx: MarketContext, at index: Int, limitUp: Double = 0.10) -> [FearSignal] {
        var out: [FearSignal] = []
        guard index >= 30, index < ctx.count else { return out }

        let c = ctx.candles[index]
        let closes = ctx.closes
        let vols = ctx.volumes
        let volMA5 = ctx.volMA5.value(index) ?? c.volume
        let volMA20 = ctx.volMA20.value(index) ?? c.volume
        let volX = volMA5 > 0 ? c.volume / volMA5 : 1
        let rsi14 = ctx.rsi14.value(index) ?? 50
        let pctRank = Indicators.percentileRank(closes, index: index, lookback: 120)

        // ---- 1. 恐慌割肉后企稳 ----
        // 前 3 日累计跌超 6% 且至少 2 日放量杀跌（恐慌盘集中宣泄），
        // 当日长下影收回、收盘位于当日高位（承接资金进场）。
        if index >= 4 {
            let base = closes[index - 4]
            let drop3 = base > 0 ? (closes[index - 1] - base) / base : 0
            var panicDays = 0
            for x in (index - 3)...(index - 1) {
                let downDay = closes[x] < closes[x - 1]
                let bigVol = vols[x] > volMA20 * 1.3
                if downDay && bigVol { panicDays += 1 }
            }
            let longLower = c.lowerShadowRatio > 0.4
            let recovered = c.closePosition > 0.55
            let caught = c.volume > volMA20 * 0.8
            if drop3 <= -0.06, panicDays >= 2, longLower, recovered, caught {
                var score = 72.0
                if panicDays >= 3 { score += 5 }
                if c.close > c.open { score += 4 }
                let reason = "连跌放量 \(Fmt.pct(drop3 * 100, decimals: 1)) 后长下影收回，"
                    + "恐慌盘集中宣泄后抛压衰竭，承接资金开始进场"
                out.append(FearSignal(kind: .panicCapitulation, score: min(100, score),
                                      reason: reason, price: c.close, date: c.date))
            }
        }

        // ---- 2. 假破位诱空 ----
        // 盘中跌破有效支撑后收回支撑上方，且当日缩量（不是真破位出逃）。
        if volX < 1.0 {
            var support: PriceLevel?
            for lv in ctx.levels {
                if lv.kind != .support { continue }
                if lv.score < 40 { continue }
                if lv.price >= closes[index - 1] { continue }
                if let cur = support {
                    if lv.price > cur.price { support = lv }
                } else {
                    support = lv
                }
            }
            if let s = support {
                let brokeIntraday = c.low < s.price * 0.995
                let closedBack = c.close > s.price
                if brokeIntraday, closedBack {
                    let reason = "盘中跌破\(s.strengthLabel)支撑 \(Fmt.price(s.price)) 后收回，"
                        + "缩量假破位，诱空洗盘特征"
                    out.append(FearSignal(kind: .fakeBreakdown, score: 70,
                                          reason: reason, price: c.close, date: c.date))
                }
            }
        }

        // ---- 3. 冰点首根放量阳 ----
        // RSI 极低或价格处历史极低分位 + 连跌后首根放量阳线。
        if rsi14 < 32 || pctRank < 12 {
            var downCount = 0
            for x in (index - 3)...(index - 1) {
                if closes[x] < closes[x - 1] { downCount += 1 }
            }
            // 前 3 日全部收跌，当日首阳
            let priorDowns = downCount >= 3
            let firstYang = c.close > c.open
            let volumeUp = volX > 1.5
            let strongClose = c.closePosition > 0.6
            if priorDowns, firstYang, volumeUp, strongClose {
                var score = 70.0
                if rsi14 < 25 { score += 6 }
                let reason = "RSI \(Fmt.price(rsi14, decimals: 0)) 极度弱势后首根放量阳线，"
                    + "恐慌情绪宣泄到极致后的修复尝试"
                out.append(FearSignal(kind: .iceFirstYang, score: min(100, score),
                                      reason: reason, price: c.close, date: c.date))
            }
        }

        // ---- 4. 恐惧衰竭 ----
        // 创 20 日新低，但近 3 日量能逐级萎缩、杀跌无量（抛盘枯竭）。
        if index >= 20 {
            var lowest = Double.greatestFiniteMagnitude
            for x in (index - 19)...(index - 1) {
                if ctx.candles[x].low < lowest { lowest = ctx.candles[x].low }
            }
            let isNewLow = c.low <= lowest
            var vol3Sum = 0.0
            for x in (index - 2)...index {
                vol3Sum += vols[x]
            }
            let vol3Avg = vol3Sum / 3
            let shrinking = vol3Avg < volMA20 * 0.7
            let lightToday = c.volume < volMA20 * 0.8
            let notAtLows = c.close > c.low * 1.002
            let shadowed = c.lowerShadowRatio > 0.25
            if isNewLow, shrinking, lightToday, notAtLows, shadowed {
                let reason = "创 20 日新低但量能逐级萎缩至均量 \(Fmt.price(vol3Avg / max(volMA20, 1), decimals: 2)) 倍，"
                    + "杀跌动能衰竭，恐慌抛盘接近枯竭"
                out.append(FearSignal(kind: .fearExhaustion, score: 68,
                                      reason: reason, price: c.close, date: c.date))
            }
        }

        // ---- 5. 高位放量滞涨 ----
        // 价格处历史高分位，放量却涨不动、上影明显（贪婪追高接力乏力）。
        if pctRank > 78 {
            let gain = c.open > 0 ? (c.close - c.open) / c.open : 0
            let smallBody = c.bodyRatio < 0.35
            let bigVol = volX > 1.8
            let upper = c.upperShadowRatio > 0.2
            if smallBody, bigVol, upper, gain < 0.01 {
                let reason = "价格处近 120 日 \(Fmt.price(pctRank, decimals: 0))% 高分位，"
                    + "放量 \(Fmt.price(volX)) 倍却涨幅仅 \(Fmt.pct(gain * 100, decimals: 1))，"
                    + "贪婪追高资金接力乏力，警惕兑现"
                out.append(FearSignal(kind: .highStall, score: 70,
                                      reason: reason, price: c.close, date: c.date))
            }
        }

        // ---- 6. 加速赶顶 ----
        // 连续 3 日涨幅加速、累计涨超 10%、量能亢奋、RSI 高位。
        if index >= 3 {
            let g1 = closes[index - 3] > 0 ? (closes[index - 2] - closes[index - 3]) / closes[index - 3] : 0
            let g2 = closes[index - 2] > 0 ? (closes[index - 1] - closes[index - 2]) / closes[index - 2] : 0
            let g3 = closes[index - 1] > 0 ? (c.close - closes[index - 1]) / closes[index - 1] : 0
            let accelerating = g1 > 0 && g2 > g1 && g3 > g2
            let totalGain = closes[index - 3] > 0 ? (c.close - closes[index - 3]) / closes[index - 3] : 0
            if accelerating, totalGain > 0.10, volX > 2.0, rsi14 > 70 {
                let reason = "连续 3 日涨幅加速（\(Fmt.pct(g1 * 100, decimals: 1)) → "
                    + "\(Fmt.pct(g2 * 100, decimals: 1)) → \(Fmt.pct(g3 * 100, decimals: 1))），"
                    + "量能亢奋，贪婪情绪进入赶顶阶段，波动将加大"
                out.append(FearSignal(kind: .blowoffTop, score: 74,
                                      reason: reason, price: c.close, date: c.date))
            }
        }

        // ---- 7. 涨停开板巨量 ----
        // 盘中触及涨停后开板回落且巨量（封板资金分歧）。无涨跌停市场跳过。
        if limitUp > 0, index >= 1 {
            let prevClose = closes[index - 1]
            let limitPrice = prevClose * (1 + limitUp)
            let touched = c.high >= limitPrice * 0.998
            let opened = c.close < c.high * 0.97
            if touched, opened, volX > 2.5 {
                let reason = "触及涨停 \(Fmt.price(limitPrice)) 后开板回落至 \(Fmt.price(c.close))，"
                    + "且放量 \(Fmt.price(volX)) 倍，封板资金分歧，追高需谨慎"
                out.append(FearSignal(kind: .limitUpOpenHuge, score: 72,
                                      reason: reason, price: c.close, date: c.date))
            }
        }

        out.sort { $0.score > $1.score }
        return out
    }
}
