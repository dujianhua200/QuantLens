import Foundation

// MARK: - 买卖点形态

/// 信号族：融合时按族去重与计票。同一族内的多个检测器共享同一份价格信息，
///
/// 不能互相印证；只有 ≥2 个独立族在同一根 K 线触发，才标"强"。
enum TradePointFamily: String, Hashable {
    case trend          // 趋势：B1/B2/S1
    case momentum       // 动量：B4
    case pullback       // 回踩：B3/B5
    case meanReversion  // 均值回归：B7
    case reversal       // 反包：B6
    case distribution   // 派发：S2/S3
}

/// 显式买卖点形态。B1~B7 为买点，S1~S3 为卖点。
///
/// 规则来源：调研蒸馏（Minervini 模板、盘整突破、均线回踩、动量放量、
/// N 字二波、首阴反包确认版、BB+RSI 均值回归、趋势破位、贪婪兑现、支撑破位）。
/// 所有规则只用日线 OHLCV + 已有指标，评估第 i 根 K 线时只读 ≤i 的数据（无前视）。
/// 组合策略未经样本外回测验证，规则参数为公开资料的起点值，不宣称收益。
enum TradePointKind: String, Hashable, CaseIterable {
    case trendTemplateBreakout  // B1
    case rangeBreakout          // B2
    case maPullback             // B3
    case momentumSurge          // B4
    case secondWave             // B5
    case confirmedReversal      // B6
    case meanReversion          // B7
    case trendBreakdown         // S1
    case greedyTop              // S2
    case supportBreak           // S3

    var code: String {
        switch self {
        case .trendTemplateBreakout: return "B1"
        case .rangeBreakout: return "B2"
        case .maPullback: return "B3"
        case .momentumSurge: return "B4"
        case .secondWave: return "B5"
        case .confirmedReversal: return "B6"
        case .meanReversion: return "B7"
        case .trendBreakdown: return "S1"
        case .greedyTop: return "S2"
        case .supportBreak: return "S3"
        }
    }

    var label: String {
        switch self {
        case .trendTemplateBreakout: return "趋势模板突破"
        case .rangeBreakout: return "平台突破"
        case .maPullback: return "均线回踩"
        case .momentumSurge: return "动量放量"
        case .secondWave: return "N字二波"
        case .confirmedReversal: return "首阴反包"
        case .meanReversion: return "超卖回归"
        case .trendBreakdown: return "趋势破位"
        case .greedyTop: return "高位兑现"
        case .supportBreak: return "跌破支撑"
        }
    }

    /// 图上窄标签（两字）
    var shortLabel: String {
        switch self {
        case .trendTemplateBreakout: return "趋势"
        case .rangeBreakout: return "平台"
        case .maPullback: return "回踩"
        case .momentumSurge: return "动量"
        case .secondWave: return "二波"
        case .confirmedReversal: return "反包"
        case .meanReversion: return "回归"
        case .trendBreakdown: return "破位"
        case .greedyTop: return "兑现"
        case .supportBreak: return "止损"
        }
    }

    var direction: TradeDirection {
        switch self {
        case .trendTemplateBreakout, .rangeBreakout, .maPullback, .momentumSurge,
             .secondWave, .confirmedReversal, .meanReversion:
            return .buy
        case .trendBreakdown, .greedyTop, .supportBreak:
            return .sell
        }
    }

    var family: TradePointFamily {
        switch self {
        case .trendTemplateBreakout, .rangeBreakout, .trendBreakdown: return .trend
        case .momentumSurge: return .momentum
        case .maPullback, .secondWave: return .pullback
        case .meanReversion: return .meanReversion
        case .confirmedReversal: return .reversal
        case .greedyTop, .supportBreak: return .distribution
        }
    }
}

// MARK: - 买卖点记录

/// 一条显式买卖点：触发价、止损、目标、强度、理由全部由规则算出。
///
/// 与旧 `markers` 机制的区别：旧机制是四类评分的阈值穿越（评分很少到 70 分，
/// 320 根只打出 2 个点）；本引擎是显式形态检测，每个点都有可复核的触发条件。
struct TradePointSignal: Identifiable, Hashable {
    let id = UUID()
    var kind: TradePointKind
    /// 触发 K 线下标（用于图上定位）
    var index: Int
    var date: Date
    /// 触发价：收盘价（B6 为次日开盘价）
    var price: Double
    /// 强度 0~100：规则证据的相对分，不是概率、不代表胜率
    var strength: Double
    var reason: String
    /// 止损价（ATR 口径）。T+1 下日内止损只是提醒，跳空可能穿止损
    var stopLoss: Double
    /// 目标价（下一压力/支撑位或 R 倍数）
    var target: Double
    var atr: Double
    /// ≥2 个独立信号族同日触发（B6 永不标强）
    var isStrong: Bool = false
    /// 环境门控否决：仅观察，不计入"强"
    var isVetoed: Bool = false
    var gateNote: String = ""
    /// 仓位级别提示，如 B6 的"最小仓位级别"（仅作观察口径，不是仓位建议）
    var sizeNote: String = ""
    /// 证据数字（量比、RSI、ADX 等）：供模板解释与 LLM 输出校验引用
    var evidence: [String: Double] = [:]

    var direction: TradeDirection { kind.direction }
    var family: TradePointFamily { kind.family }

    var risk: Double { abs(price - stopLoss) }
    var reward: Double { abs(target - price) }
    var rMultiple: Double { risk > 0 ? reward / risk : 0 }
}

// MARK: - 环境门控（只否决、不加分）

/// 指数趋势状态：未知时门控不拦（数据缺失不得把所有信号拦掉）。
enum IndexTrendState: String, Hashable {
    case bullish = "指数走强"
    case bearish = "指数走弱"
    case unknown = "指数未知"
}

/// 环境门控输入。两道门都确认恶化时才否决买点；任一数据缺失即放行。
struct TradePointGates {
    var indexTrend: IndexTrendState = .unknown
    var breadth: MarketBreadth?

    static let unknown = TradePointGates()

    /// 否决条件（保守）：指数收盘在下行 MA20 之下，且宽度样本 ≥20 只、上涨占比 <30%。
    /// 卖点永不被否决（弱市中的卖出信号本身就是风险提示）。
    var vetoBuys: Bool {
        guard indexTrend == .bearish else { return false }
        guard let b = breadth, b.total >= 20 else { return false }
        return b.advanceRatio < 0.30
    }
}

// MARK: - 引擎专用特征

/// `MarketContext` 之外的补充特征（SMA50/150/200、ADX、50 日均量），一次性算好。
struct TradePointFeatures {
    var ma50: [Double]
    var ma150: [Double]
    var ma200: [Double]
    var adx: [Double]
    var volMA50: [Double]

    static func build(candles: [Candle], closes: [Double], volumes: [Double]) -> TradePointFeatures {
        TradePointFeatures(
            ma50: Indicators.sma(closes, period: 50),
            ma150: Indicators.sma(closes, period: 150),
            ma200: Indicators.sma(closes, period: 200),
            adx: Indicators.adx(candles, period: 14),
            volMA50: Indicators.sma(volumes, period: 50)
        )
    }
}

// MARK: - 买卖点引擎

enum TradePointEngine {

    // MARK: 指数趋势（门控输入，纯函数）

    /// 指数趋势判定：收盘在 MA20 之上且 MA20 上行 → 走强；
    /// 收盘在 MA20 之下且 MA20 下行 → 走弱；其余 → 未知（门控放行）。
    static func indexTrend(from candles: [Candle]) -> IndexTrendState {
        guard candles.count >= 26 else { return .unknown }
        var closes: [Double] = []
        for c in candles { closes.append(c.close) }
        let ma20 = Indicators.sma(closes, period: 20)
        let last = closes.count - 1
        guard let m20 = ma20.value(last) else { return .unknown }
        guard let m20prev = ma20.value(last - 5) else { return .unknown }
        let price = closes[last]
        if price > m20, m20 >= m20prev { return .bullish }
        if price < m20, m20 < m20prev { return .bearish }
        return .unknown
    }

    // MARK: 目标位辅助

    static func nextResistanceAbove(_ levels: [PriceLevel], price: Double) -> Double? {
        var best: Double?
        for lv in levels {
            if lv.kind != .resistance { continue }
            if lv.price <= price { continue }
            if let cur = best {
                if lv.price < cur { best = lv.price }
            } else {
                best = lv.price
            }
        }
        return best
    }

    static func nextSupportBelow(_ levels: [PriceLevel], price: Double) -> Double? {
        var best: Double?
        for lv in levels {
            if lv.kind != .support { continue }
            if lv.price >= price { continue }
            if let cur = best {
                if lv.price > cur { best = lv.price }
            } else {
                best = lv.price
            }
        }
        return best
    }

    /// 买点目标位：15% 内的最近压力位优先，否则 2R；保底高于触发价 + 0.5R。
    static func buyTarget(price: Double, risk: Double, levels: [PriceLevel], measuredMove: Double? = nil) -> Double {
        var target = price + 2 * risk
        if let m = measuredMove, m > price { target = min(target, m) }
        if let r = nextResistanceAbove(levels, price: price) {
            if r <= price * 1.15, r > price { target = min(target, r) }
        }
        let floor = price + 0.5 * risk
        if target < floor { target = floor }
        return target
    }

    /// 卖点目标位：15% 内的最近支撑位优先，否则 2R；保底低于触发价 − 0.5R。
    static func sellTarget(price: Double, risk: Double, levels: [PriceLevel]) -> Double {
        var target = price - 2 * risk
        if let s = nextSupportBelow(levels, price: price) {
            if s >= price * 0.85, s < price { target = max(target, s) }
        }
        let cap = price - 0.5 * risk
        if target > cap { target = cap }
        return target
    }

    // MARK: B1 趋势模板 + 52 周高突破

    /// Minervini 模板简化版：价格在 SMA50/150/200 之上、SMA50 在上、
    /// SMA200 上行、收盘创近 252 日收盘新高、量 ≥1.5×50 日均量。
    static func detectTrendTemplate(ctx: MarketContext, features: TradePointFeatures, at index: Int) -> TradePointSignal? {
        guard index >= 200, index < ctx.count else { return nil }
        let c = ctx.candles[index]
        guard let ma50 = features.ma50.value(index) else { return nil }
        guard let ma150 = features.ma150.value(index) else { return nil }
        guard let ma200 = features.ma200.value(index) else { return nil }
        guard let ma200prev = features.ma200.value(index - 20) else { return nil }
        guard let volMA50 = features.volMA50.value(index), volMA50 > 0 else { return nil }
        guard c.close > ma50, c.close > ma150, c.close > ma200 else { return nil }
        guard ma50 > ma150, ma150 > ma200 else { return nil }
        guard ma200 >= ma200prev else { return nil }

        let lookback = min(252, index)
        var priorCloseHigh = 0.0
        for j in (index - lookback)..<index {
            if ctx.closes[j] > priorCloseHigh { priorCloseHigh = ctx.closes[j] }
        }
        guard c.close > priorCloseHigh else { return nil }
        let volX = c.volume / volMA50
        guard volX >= 1.5 else { return nil }

        let atr = ctx.atr.value(index) ?? 0
        var stop = c.close - 2 * atr
        let maxStop = c.close * 0.93
        if stop < maxStop { stop = maxStop }
        let risk = c.close - stop
        let target = buyTarget(price: c.close, risk: risk, levels: ctx.levels)

        var strength = 72.0
        if volX >= 2.0 { strength += 6 }
        let margin = priorCloseHigh > 0 ? (c.close - priorCloseHigh) / priorCloseHigh : 0
        if margin > 0.01 { strength += 4 }
        let reason = "站上 SMA50/150/200 多头模板且 SMA200 上行，收盘创近 \(lookback) 日新高，"
            + "成交量为 50 日均量 \(Fmt.price(volX)) 倍"
        return TradePointSignal(
            kind: .trendTemplateBreakout, index: index, date: c.date, price: c.close,
            strength: min(88, strength), reason: reason, stopLoss: stop, target: target, atr: atr,
            evidence: ["volumeMultiple": volX, "highLookback": Double(lookback)]
        )
    }

    // MARK: B2 平台 / 盘整突破

    /// 20 日箱体（振幅 ≤15%）、箱内量能萎缩、收盘突破箱顶、量 ≥2×20 日均量。
    static func detectRangeBreakout(ctx: MarketContext, at index: Int) -> TradePointSignal? {
        guard index >= 25, index < ctx.count else { return nil }
        let c = ctx.candles[index]
        var rangeHigh = 0.0
        var rangeLow = Double.greatestFiniteMagnitude
        for j in (index - 20)..<index {
            if ctx.candles[j].high > rangeHigh { rangeHigh = ctx.candles[j].high }
            if ctx.candles[j].low < rangeLow { rangeLow = ctx.candles[j].low }
        }
        guard rangeLow > 0 else { return nil }
        let width = (rangeHigh - rangeLow) / rangeLow
        guard width <= 0.15 else { return nil }
        guard c.close > rangeHigh else { return nil }

        let volMA20 = ctx.volMA20.value(index) ?? c.volume
        guard volMA20 > 0 else { return nil }
        let volX = c.volume / volMA20
        guard volX >= 2.0 else { return nil }
        if let ma20 = ctx.ma20.value(index) {
            guard c.close > ma20 else { return nil }
        }
        // 箱内量能萎缩：最近 5 根均量低于 20 日均量
        var recentVol = 0.0
        for j in (index - 5)..<index { recentVol += ctx.volumes[j] }
        let recentAvg = recentVol / 5
        guard recentAvg < volMA20 else { return nil }

        let atr = ctx.atr.value(index) ?? 0
        var stop = min(c.low, rangeHigh) - 0.5 * atr
        if stop > c.close - 0.3 * atr { stop = c.close - 1 * atr }
        let risk = c.close - stop
        let measuredMove = c.close + (rangeHigh - rangeLow)
        let target = buyTarget(price: c.close, risk: risk, levels: ctx.levels, measuredMove: measuredMove)

        var strength = 70.0
        if volX >= 3.0 { strength += 6 }
        let reason = "突破 20 日箱顶 \(Fmt.price(rangeHigh))（箱体振幅 \(Fmt.pct(width * 100, decimals: 1))），"
            + "箱内缩量后放量 \(Fmt.price(volX)) 倍确认"
        return TradePointSignal(
            kind: .rangeBreakout, index: index, date: c.date, price: c.close,
            strength: min(88, strength), reason: reason, stopLoss: stop, target: target, atr: atr,
            evidence: ["volumeMultiple": volX, "rangeWidthPct": width * 100]
        )
    }

    // MARK: B3 均线回踩

    /// 多头排列 + MA20 上行，低点触及 MA20/MA10 后收回、缩量收阳。
    static func detectMAPullback(ctx: MarketContext, at index: Int) -> TradePointSignal? {
        guard index >= 25, index < ctx.count else { return nil }
        let c = ctx.candles[index]
        guard let ma5 = ctx.ma5.value(index) else { return nil }
        guard let ma10 = ctx.ma10.value(index) else { return nil }
        guard let ma20 = ctx.ma20.value(index) else { return nil }
        guard let ma20prev = ctx.ma20.value(index - 5) else { return nil }
        guard ma5 > ma10, ma10 > ma20, ma20 > ma20prev else { return nil }

        // 触线：优先 MA20，其次 MA10（低点贴线但未深破，收盘收回线上）
        var touchedMA: Double?
        var maLabel = ""
        if c.low <= ma20 * 1.005, c.low >= ma20 * 0.97, c.close > ma20 {
            touchedMA = ma20
            maLabel = "MA20"
        } else if c.low <= ma10 * 1.005, c.low >= ma10 * 0.97, c.close > ma10 {
            touchedMA = ma10
            maLabel = "MA10"
        }
        guard let touched = touchedMA else { return nil }
        guard c.close > c.open, c.closePosition > 0.5 else { return nil }

        let volMA20 = ctx.volMA20.value(index) ?? c.volume
        guard volMA20 > 0 else { return nil }
        let volX = c.volume / volMA20
        guard volX < 0.9 else { return nil }

        let atr = ctx.atr.value(index) ?? 0
        let stop = min(c.low, touched) - 0.5 * atr
        let risk = c.close - stop
        let target = buyTarget(price: c.close, risk: risk, levels: ctx.levels)

        var strength = 68.0
        if volX < 0.6 { strength += 4 }
        let reason = "多头排列中回踩 \(maLabel) \(Fmt.price(touched)) 不破，"
            + "缩量（\(Fmt.price(volX)) 倍均量）收阳回升"
        return TradePointSignal(
            kind: .maPullback, index: index, date: c.date, price: c.close,
            strength: min(88, strength), reason: reason, stopLoss: stop, target: target, atr: atr,
            evidence: ["volumeMultiple": volX]
        )
    }

    // MARK: B4 动量 + 放量

    /// 20 日涨幅 ≥8% 且动量拐头向上、量 ≥2 倍、OBV 创 20 日新高、非涨停追高。
    static func detectMomentumSurge(ctx: MarketContext, at index: Int, limitUp: Double) -> TradePointSignal? {
        guard index >= 25, index < ctx.count else { return nil }
        let c = ctx.candles[index]
        let base = ctx.closes[index - 20]
        let prevBase = ctx.closes[index - 21]
        guard base > 0, prevBase > 0 else { return nil }
        let roc20 = (c.close - base) / base
        let prevRoc20 = (ctx.closes[index - 1] - prevBase) / prevBase
        guard roc20 >= 0.08, roc20 > prevRoc20 else { return nil }

        let volMA20 = ctx.volMA20.value(index) ?? c.volume
        guard volMA20 > 0 else { return nil }
        let volX = c.volume / volMA20
        guard volX >= 2.0 else { return nil }

        var obvHigh = 0.0
        var obvPrevHigh = -Double.greatestFiniteMagnitude
        for j in (index - 20)..<index {
            if ctx.obv[j] > obvPrevHigh { obvPrevHigh = ctx.obv[j] }
        }
        obvHigh = ctx.obv[index]
        guard obvHigh >= obvPrevHigh else { return nil }

        if let ma20 = ctx.ma20.value(index) {
            guard c.close > ma20 else { return nil }
        }
        let prevClose = ctx.closes[index - 1]
        let gain = prevClose > 0 ? (c.close - prevClose) / prevClose : 0
        let climaxCap = limitUp > 0 ? limitUp * 0.9 : 0.12
        guard gain < climaxCap else { return nil }

        let atr = ctx.atr.value(index) ?? 0
        let stop = c.close - 2 * atr
        let risk = c.close - stop
        let target = buyTarget(price: c.close, risk: risk, levels: ctx.levels)

        var strength = 66.0
        if roc20 >= 0.15 { strength += 5 }
        if volX >= 3.0 { strength += 4 }
        let reason = "20 日涨幅 \(Fmt.pct(roc20 * 100, decimals: 1)) 且动量拐头向上，"
            + "放量 \(Fmt.price(volX)) 倍，OBV 同步创 20 日新高"
        return TradePointSignal(
            kind: .momentumSurge, index: index, date: c.date, price: c.close,
            strength: min(88, strength), reason: reason, stopLoss: stop, target: target, atr: atr,
            evidence: ["volumeMultiple": volX, "roc20Pct": roc20 * 100]
        )
    }

    // MARK: B5 N 字 / 空中加油二波

    /// 一波上涨 ≥10% → 回踩 3%~20%（>20% 无效）守住 MA20、量能萎缩 →
    /// 放量突破整理高点。回踩过深或破 MA20 均不触发。
    static func detectSecondWave(ctx: MarketContext, at index: Int) -> TradePointSignal? {
        guard index >= 50, index < ctx.count else { return nil }
        let c = ctx.candles[index]

        // 一波高点：30 日内、至少 5 日前的高点
        var waveHigh = 0.0
        var waveHighIndex = -1
        for j in (index - 30)...(index - 5) {
            if ctx.candles[j].high > waveHigh {
                waveHigh = ctx.candles[j].high
                waveHighIndex = j
            }
        }
        guard waveHighIndex > 0 else { return nil }
        var waveLow = Double.greatestFiniteMagnitude
        let waveStart = max(0, waveHighIndex - 20)
        for j in waveStart...waveHighIndex {
            if ctx.candles[j].low < waveLow { waveLow = ctx.candles[j].low }
        }
        guard waveLow > 0 else { return nil }
        let waveGain = (waveHigh - waveLow) / waveLow
        guard waveGain >= 0.10 else { return nil }

        // 整理段：高点之后、今日之前，至少 3 根
        let phaseStart = waveHighIndex + 1
        let phaseEnd = index - 1
        guard phaseEnd - phaseStart >= 2 else { return nil }
        var pullbackLow = Double.greatestFiniteMagnitude
        var consolHigh = 0.0
        var phaseVol = 0.0
        var heldMA20 = true
        for j in phaseStart...phaseEnd {
            if ctx.candles[j].low < pullbackLow { pullbackLow = ctx.candles[j].low }
            if ctx.candles[j].high > consolHigh { consolHigh = ctx.candles[j].high }
            phaseVol += ctx.volumes[j]
            if let m20 = ctx.ma20.value(j) {
                if ctx.closes[j] < m20 * 0.995 { heldMA20 = false }
            }
        }
        guard heldMA20 else { return nil }
        let depth = (waveHigh - pullbackLow) / waveHigh
        guard depth >= 0.03, depth <= 0.20 else { return nil }

        let volMA20 = ctx.volMA20.value(index) ?? c.volume
        guard volMA20 > 0 else { return nil }
        let phaseCount = Double(phaseEnd - phaseStart + 1)
        let phaseAvgVol = phaseVol / phaseCount
        guard phaseAvgVol < volMA20 else { return nil }

        guard c.close > consolHigh else { return nil }
        let volX = c.volume / volMA20
        guard volX >= 1.5 else { return nil }

        let atr = ctx.atr.value(index) ?? 0
        let stop = pullbackLow - 0.5 * atr
        let risk = c.close - stop
        let measuredMove = c.close + (waveHigh - pullbackLow)
        let target = buyTarget(price: c.close, risk: risk, levels: ctx.levels, measuredMove: measuredMove)

        let reason = "一波上涨 \(Fmt.pct(waveGain * 100, decimals: 1)) 后回踩 "
            + "\(Fmt.pct(depth * 100, decimals: 1)) 守住 MA20、量能萎缩，"
            + "放量 \(Fmt.price(volX)) 倍突破整理高点 \(Fmt.price(consolHigh))"
        return TradePointSignal(
            kind: .secondWave, index: index, date: c.date, price: c.close,
            strength: 70, reason: reason, stopLoss: stop, target: target, atr: atr,
            evidence: ["volumeMultiple": volX, "pullbackPct": depth * 100, "waveGainPct": waveGain * 100]
        )
    }

    // MARK: B6 确认式首阴反包（严格版，最小仓位级别）

    /// ≥2 连板 → 首阴 → 次日涨停收盘且收盘 ≥ 首阴开盘（实体反包）→
    /// 再下一日开盘溢价 ≤5.5% 才触发，触发价为当日开盘价。
    /// 样本依据极弱（公开回测仅 7 笔），永不标"强"，理由中注明。
    /// 评估下标 t = D+1（买入日）：t-4/t-3 连板，t-2 首阴，t-1 反包，t 为开盘日。
    static func detectConfirmedReversal(ctx: MarketContext, at index: Int, limitUp: Double) -> TradePointSignal? {
        guard limitUp > 0, index >= 5, index < ctx.count else { return nil }
        let closes = ctx.closes
        let candles = ctx.candles

        func isLimitUp(_ j: Int) -> Bool {
            guard j >= 1 else { return false }
            let prev = closes[j - 1]
            return prev > 0 && closes[j] >= prev * (1 + limitUp) * 0.995
        }

        guard isLimitUp(index - 4), isLimitUp(index - 3) else { return nil }
        let firstShade = candles[index - 2]
        guard firstShade.close < firstShade.open else { return nil }
        guard firstShade.close < closes[index - 3] else { return nil }
        let reversal = candles[index - 1]
        guard isLimitUp(index - 1) else { return nil }
        guard reversal.close >= firstShade.open else { return nil }

        let c = candles[index]
        let prevClose = closes[index - 1]
        guard prevClose > 0 else { return nil }
        let premium = c.open / prevClose - 1
        guard premium <= 0.055 else { return nil }

        let entry = c.open
        let stop = entry * 0.93
        let target = entry * 1.07
        let atr = ctx.atr.value(index) ?? 0
        let reason = "连板后首阴、次日涨停反包（收盘 \(Fmt.price(reversal.close)) ≥ 首阴开盘 "
            + "\(Fmt.price(firstShade.open))），今日开盘溢价 \(Fmt.pct(premium * 100, decimals: 1)) ≤ 5.5%。"
            + "样本依据极弱（公开回测仅 7 笔），仅作最小仓位级别观察"
        return TradePointSignal(
            kind: .confirmedReversal, index: index, date: c.date, price: entry,
            strength: 60, reason: reason, stopLoss: stop, target: target, atr: atr,
            sizeNote: "最小仓位级别",
            evidence: ["openPremiumPct": premium * 100]
        )
    }

    // MARK: B7 BB + RSI 均值回归（仅震荡市）

    /// ADX<25 门控：触布林下轨后收回带内 + RSI(14)<30 + 收阳 + 未创 20 日新低。
    /// 中轨（MA20）为止盈目标。趋势市中 ADX 门控直接拦掉。
    static func detectMeanReversion(ctx: MarketContext, features: TradePointFeatures, at index: Int) -> TradePointSignal? {
        guard index >= 30, index < ctx.count else { return nil }
        let c = ctx.candles[index]
        guard let adx = features.adx.value(index), adx < 25 else { return nil }
        guard let lower = ctx.boll.lower.value(index) else { return nil }
        guard let mid = ctx.boll.mid.value(index) else { return nil }
        guard c.close <= lower * 1.005, c.close > lower else { return nil }
        guard c.close > c.open else { return nil }
        let rsi14 = ctx.rsi14.value(index) ?? 50
        guard rsi14 < 30 else { return nil }
        var minLow20 = Double.greatestFiniteMagnitude
        for j in (index - 20)..<index {
            if ctx.candles[j].low < minLow20 { minLow20 = ctx.candles[j].low }
        }
        guard c.low >= minLow20 * 0.995 else { return nil }

        let atr = ctx.atr.value(index) ?? 0
        let stop = c.low - 0.5 * atr
        let risk = c.close - stop
        var target = mid
        if target < c.close + 0.5 * risk { target = c.close + 1 * risk }
        let reason = "震荡市（ADX \(Fmt.price(adx, decimals: 0))<25），触布林下轨 \(Fmt.price(lower)) 后收回，"
            + "RSI(14) \(Fmt.price(rsi14, decimals: 0)) 超卖收阳，未创 20 日新低"
        return TradePointSignal(
            kind: .meanReversion, index: index, date: c.date, price: c.close,
            strength: 64, reason: reason, stopLoss: stop, target: target, atr: atr,
            evidence: ["adx": adx, "rsi14": rsi14]
        )
    }

    // MARK: S1 趋势破位

    /// 新鲜收盘破 MA20 + MA20 拐头向下 + 收盘在 MA60 之下（MA60 存在时）。
    static func detectTrendBreakdown(ctx: MarketContext, at index: Int) -> TradePointSignal? {
        guard index >= 25, index < ctx.count else { return nil }
        let c = ctx.candles[index]
        guard let ma20 = ctx.ma20.value(index) else { return nil }
        guard let ma20prevBar = ctx.ma20.value(index - 1) else { return nil }
        guard let ma20prev = ctx.ma20.value(index - 5) else { return nil }
        guard ctx.closes[index - 1] >= ma20prevBar else { return nil }
        guard c.close < ma20 else { return nil }
        guard ma20 < ma20prev else { return nil }
        if let ma60 = ctx.ma60.value(index) {
            guard c.close < ma60 else { return nil }
        }

        let atr = ctx.atr.value(index) ?? 0
        var stop = c.close + 2 * atr
        let maStop = ma20 * 1.01
        if stop < maStop { stop = maStop }
        let risk = stop - c.close
        let target = sellTarget(price: c.close, risk: risk, levels: ctx.levels)
        let reason = "收盘跌破 MA20 \(Fmt.price(ma20)) 且 MA20 拐头向下，"
            + "中期趋势翻空，跌破当日收盘价 \(Fmt.price(c.close))"
        return TradePointSignal(
            kind: .trendBreakdown, index: index, date: c.date, price: c.close,
            strength: 68, reason: reason, stopLoss: stop, target: target, atr: atr,
            evidence: [:]
        )
    }

    // MARK: S2 高位兑现（复用贪婪信号）

    /// FearSignals 的贪婪类（高位滞涨/加速赶顶/涨停开板）转译为卖点，理由原样保留。
    static func sellPoint(from fear: FearSignal, index: Int, ctx: MarketContext) -> TradePointSignal? {
        guard fear.direction == .sell else { return nil }
        let atr = ctx.atr.value(index) ?? 0
        let stop = fear.price + 2 * atr
        let risk = stop - fear.price
        let target = sellTarget(price: fear.price, risk: risk, levels: ctx.levels)
        return TradePointSignal(
            kind: .greedyTop, index: index, date: fear.date, price: fear.price,
            strength: fear.score, reason: fear.reason + "（贪婪信号）",
            stopLoss: stop, target: target, atr: atr,
            evidence: [:]
        )
    }

    // MARK: S3 跌破支撑 / 止损触发

    /// 新鲜收盘跌破前 20 日最低点（关键支撑位）。无前视：支撑只用历史 K 线。
    static func detectSupportBreak(ctx: MarketContext, at index: Int) -> TradePointSignal? {
        guard index >= 25, index < ctx.count else { return nil }
        let c = ctx.candles[index]
        var support20 = Double.greatestFiniteMagnitude
        for j in (index - 20)..<index {
            if ctx.candles[j].low < support20 { support20 = ctx.candles[j].low }
        }
        guard support20 < Double.greatestFiniteMagnitude else { return nil }
        guard ctx.closes[index - 1] >= support20 else { return nil }
        guard c.close < support20 * 0.995 else { return nil }

        let atr = ctx.atr.value(index) ?? 0
        let stop = c.close + 2 * atr
        let risk = stop - c.close
        let target = sellTarget(price: c.close, risk: risk, levels: ctx.levels)
        let reason = "收盘跌破前 20 日关键支撑 \(Fmt.price(support20))，"
            + "结构破位，止损提醒触发"
        return TradePointSignal(
            kind: .supportBreak, index: index, date: c.date, price: c.close,
            strength: 70, reason: reason, stopLoss: stop, target: target, atr: atr,
            evidence: ["support20": support20]
        )
    }

    // MARK: 全量评估 + 融合

    /// 对 [from, count) 逐根评估全部检测器，返回融合后的买卖点与逐根恐惧/贪婪信号。
    ///
    /// 融合规则：同族 5 根内冷却去重（只留强度最高的一条）；同一根 ≥2 个独立族
    /// 触发则标"强"（B6 除外）；环境门控只否决买点、不加分。
    static func evaluateAll(ctx: MarketContext,
                            from: Int,
                            limitUp: Double,
                            gates: TradePointGates = .unknown)
    -> (points: [TradePointSignal], fearHistory: [FearSignal]) {
        let features = TradePointFeatures.build(candles: ctx.candles, closes: ctx.closes, volumes: ctx.volumes)
        var raw: [TradePointSignal] = []
        var fearHistory: [FearSignal] = []
        let start = max(30, from)
        guard start < ctx.count else { return ([], []) }

        for i in start..<ctx.count {
            if let p = detectTrendTemplate(ctx: ctx, features: features, at: i) { raw.append(p) }
            if let p = detectRangeBreakout(ctx: ctx, at: i) { raw.append(p) }
            if let p = detectMAPullback(ctx: ctx, at: i) { raw.append(p) }
            if let p = detectMomentumSurge(ctx: ctx, at: i, limitUp: limitUp) { raw.append(p) }
            if let p = detectSecondWave(ctx: ctx, at: i) { raw.append(p) }
            if let p = detectConfirmedReversal(ctx: ctx, at: i, limitUp: limitUp) { raw.append(p) }
            if let p = detectMeanReversion(ctx: ctx, features: features, at: i) { raw.append(p) }
            if let p = detectTrendBreakdown(ctx: ctx, at: i) { raw.append(p) }
            if let p = detectSupportBreak(ctx: ctx, at: i) { raw.append(p) }
            let fears = FearSignals.evaluate(ctx, at: i, limitUp: limitUp)
            for f in fears {
                fearHistory.append(f)
                if let p = sellPoint(from: f, index: i, ctx: ctx) { raw.append(p) }
            }
        }

        let fused = fuse(raw, gates: gates)
        return (fused, fearHistory)
    }

    /// 融合（纯函数，可单测）：同族 5 根冷却去重 → 同日多族共振标"强" → 门控否决买点。
    static func fuse(_ raw: [TradePointSignal], gates: TradePointGates) -> [TradePointSignal] {
        // 同族冷却去重：按（下标升序、强度降序）遍历，同族 5 根内只留第一条
        var sorted = raw
        sorted.sort { a, b in
            if a.index != b.index { return a.index < b.index }
            return a.strength > b.strength
        }
        var lastKeptByFamily: [TradePointFamily: Int] = [:]
        var deduped: [TradePointSignal] = []
        for p in sorted {
            if let last = lastKeptByFamily[p.family], p.index - last < 5 { continue }
            lastKeptByFamily[p.family] = p.index
            deduped.append(p)
        }

        // 同日多族共振标"强"（B6 除外）
        var familiesByIndex: [Int: Set<TradePointFamily>] = [:]
        for p in deduped {
            var set = familiesByIndex[p.index] ?? Set<TradePointFamily>()
            set.insert(p.family)
            familiesByIndex[p.index] = set
        }
        var fused: [TradePointSignal] = []
        for var p in deduped {
            let familyCount = familiesByIndex[p.index]?.count ?? 0
            if familyCount >= 2, p.kind != .confirmedReversal {
                p.isStrong = true
            }
            if gates.vetoBuys, p.direction == .buy {
                p.isVetoed = true
                p.isStrong = false
                p.gateNote = "指数走弱且市场宽度恶化，环境门控否决，仅观察"
            }
            fused.append(p)
        }
        return fused
    }
}
