import Foundation

// MARK: - 交易时段

/// 各市场连续交易时段判断（用于实时买点榜的轮询门控：非交易时段不空转）。
///
/// 口径与 `AuctionScanner.phase()` 一致：公历 + 市场所在时区 + 周末排除。
/// 不含节假日表——节假日当天接口返回静态数据，触发集合不变，
/// 榜单只会显示旧触发而不会产生新触发，危害有限，故不引入节假日维护成本。
enum TradingHours {

    /// 是否处于连续交易时段（含开盘分钟，不含收盘分钟）。
    static func isTrading(market: Market, at date: Date = Date()) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        switch market {
        case .us:
            cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        default:
            // A 股 / 北交所 / 港股 / 指数均按北京时间
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        }
        let comp = cal.dateComponents([.hour, .minute, .weekday], from: date)
        guard let h = comp.hour, let m = comp.minute, let wd = comp.weekday else { return false }
        // 周末不交易（weekday: 1=周日，7=周六）
        if wd == 1 || wd == 7 { return false }
        let t = h * 60 + m

        switch market {
        case .sh, .sz, .bj, .index:
            return (t >= 9 * 60 + 30 && t < 11 * 60 + 30) || (t >= 13 * 60 && t < 15 * 60)
        case .hk:
            return (t >= 9 * 60 + 30 && t < 12 * 60) || (t >= 13 * 60 && t < 16 * 60)
        case .us:
            return t >= 9 * 60 + 30 && t < 16 * 60
        }
    }

    /// A 股是否处于交易时段（买点榜只覆盖 A 股分时，用任一 A 股市场判断即可）。
    static func isAStockTrading(at date: Date = Date()) -> Bool {
        isTrading(market: .sh, at: date)
    }
}

// MARK: - 分时触发

/// 分时触发类型。买向触发进入买点榜，卖向触发进入卖点提醒。
enum IntradayTriggerKind: String, Hashable, CaseIterable {
    case dipToAverage      // 回踩均价线不破
    case breakoutHigh      // 放量突破分时高点
    case volumeSurge       // 量比异动（放量上攻）
    case belowAverageWeak  // 均价线下弱势
    case stalledHigh       // 高位放量滞涨
    case breakdownLow      // 放量跌破日内低点

    var label: String {
        switch self {
        case .dipToAverage: return "回踩均价"
        case .breakoutHigh: return "突破新高"
        case .volumeSurge: return "放量上攻"
        case .belowAverageWeak: return "均线下弱势"
        case .stalledHigh: return "高位滞涨"
        case .breakdownLow: return "跌破新低"
        }
    }

    var direction: TradeDirection {
        switch self {
        case .dipToAverage, .breakoutHigh, .volumeSurge: return .buy
        case .belowAverageWeak, .stalledHigh, .breakdownLow: return .sell
        }
    }
}

/// 一次分时触发：触发时刻以评估点（最新分时点）为准，
/// 首次出现时间由榜单层（AppState）跨轮次记录。
struct IntradayTrigger: Hashable {
    var kind: IntradayTriggerKind
    var direction: TradeDirection
    var price: Double
    var time: Date
    var index: Int
    /// 触发强度 0~100，仅用于榜单内排序，不代表概率
    var strength: Double
    var reason: String
}

// MARK: - 分时信号引擎

/// 基于逐分钟分时点的短线触发引擎。
///
/// 数据口径（全部复用现有数据层，不新增接口）：
/// - 价格/量：腾讯 `minute/query` 逐分钟点（`IntradayService.intraday`）
/// - 均价线：`IntradayPoint.avgPrice`，即累计成交额 / 累计成交量，
///   也就是分时图里的黄线、成交量加权均价（VWAP）
/// - 量比：与 `LocalAnalyst` 同口径，最近 N 分钟均量 / 全天每分钟均量
///
/// 降级：分时点不足 10 个、昨收缺失时返回空触发，不产生假信号。
/// 港美股没有分时接口，榜单层只对 A 股调用本引擎（见 AppState）。
enum IntradaySignals {

    /// 评估最新分时点上的全部触发，按强度降序返回。
    static func evaluate(intraday: IntradayData) -> [IntradayTrigger] {
        let pts = intraday.points
        let prev = intraday.previousClose
        guard pts.count >= 10, prev > 0 else { return [] }
        let lastIdx = pts.count - 1
        let last = pts[lastIdx]
        guard last.price > 0, last.avgPrice > 0 else { return [] }

        // 全天每分钟均量（与 LocalAnalyst 同口径）
        let avgVol = pts.map(\.volume).reduce(0, +) / Double(pts.count)

        func recentVolRatio(window: Int) -> Double {
            guard avgVol > 0 else { return 1 }
            let w = min(window, pts.count)
            let recent = pts.suffix(w).map(\.volume).reduce(0, +) / Double(w)
            return recent / avgVol
        }

        func changeVs(minutesAgo: Int) -> Double? {
            let idx = lastIdx - minutesAgo
            guard idx >= 0, pts[idx].price > 0 else { return nil }
            return (last.price / pts[idx].price - 1) * 100
        }

        var out: [IntradayTrigger] = []
        let vol5 = recentVolRatio(window: 5)

        // ── 买 1：回踩均价线不破 ──
        // 过去 15 分钟内曾跌到均价线下方（浅破不超过 1.5%），
        // 现价已收回均价线上方，且相对踩点回升超过 0.1%。
        if last.price >= last.avgPrice {
            let windowStart = max(0, lastIdx - 14)
            var dipIndex: Int?
            var dipDepth = 0.0
            for i in windowStart...lastIdx {
                let p = pts[i]
                guard p.avgPrice > 0 else { continue }
                if p.price < p.avgPrice {
                    dipIndex = i
                    dipDepth = max(dipDepth, (p.avgPrice - p.price) / p.avgPrice)
                }
            }
            if let di = dipIndex, dipDepth <= 0.015 {
                let dipLow = pts[di].price
                let dipAvg = pts[di].avgPrice
                if last.price > dipLow * 1.001 {
                    var strength = 65.0
                    // 踩点缩量说明抛压衰竭（与 LocalAnalyst 买点确认同口径）
                    if avgVol > 0, pts[di].volume < avgVol * 0.8 { strength += 8 }
                    out.append(IntradayTrigger(
                        kind: .dipToAverage, direction: .buy,
                        price: last.price, time: last.time, index: lastIdx,
                        strength: min(strength, 90),
                        reason: "回踩均价线 \(Fmt.price(dipAvg)) 至 \(Fmt.price(dipLow)) 不破后回升，现价 \(Fmt.price(last.price))"
                    ))
                }
            }
        }

        // ── 买 2：放量突破分时高点 ──
        if pts.count >= 20 {
            let prevHigh = pts[0..<lastIdx].map(\.price).max() ?? 0
            if prevHigh > 0, last.price > prevHigh * 1.001, vol5 >= 1.5 {
                let strength = 70 + min(15, (vol5 - 1.5) * 10)
                out.append(IntradayTrigger(
                    kind: .breakoutHigh, direction: .buy,
                    price: last.price, time: last.time, index: lastIdx,
                    strength: min(strength, 90),
                    reason: "放量 \(Fmt.price(vol5)) 倍突破日内高点 \(Fmt.price(prevHigh))，现价 \(Fmt.price(last.price))"
                ))
            }
        }

        // ── 买 3：量比异动（放量上攻）──
        if vol5 >= 2.0, let chg = changeVs(minutesAgo: 10), chg >= 0.5 {
            let strength = 60 + min(15, (vol5 - 2.0) * 8)
            out.append(IntradayTrigger(
                kind: .volumeSurge, direction: .buy,
                price: last.price, time: last.time, index: lastIdx,
                strength: min(strength, 85),
                reason: "近 5 分钟量比 \(Fmt.price(vol5)) 倍，10 分钟上涨 \(Fmt.pct(chg, decimals: 1))，放量上攻"
            ))
        }

        // ── 卖 1：均价线下弱势 ──
        if last.price < last.avgPrice * 0.998 {
            let windowStart = max(0, lastIdx - 9)
            let belowCount = pts[windowStart...lastIdx].filter { $0.price < $0.avgPrice }.count
            if belowCount >= 8, let chg = changeVs(minutesAgo: 10), chg <= -0.3 {
                out.append(IntradayTrigger(
                    kind: .belowAverageWeak, direction: .sell,
                    price: last.price, time: last.time, index: lastIdx,
                    strength: 65,
                    reason: "价格持续在均价线下方，10 分钟下跌 \(Fmt.pct(chg, decimals: 1))，分时弱势"
                ))
            }
        }

        // ── 卖 2：高位放量滞涨 ──
        if intraday.dayHigh > intraday.dayLow {
            let dayPos = (last.price - intraday.dayLow) / (intraday.dayHigh - intraday.dayLow)
            if dayPos > 0.85, vol5 >= 1.5, let chg = changeVs(minutesAgo: 10), chg < 0.2, chg > -0.5 {
                out.append(IntradayTrigger(
                    kind: .stalledHigh, direction: .sell,
                    price: last.price, time: last.time, index: lastIdx,
                    strength: 62,
                    reason: "处于日内高位 \(Fmt.price(dayPos * 100, decimals: 0))% 分位，放量 \(Fmt.price(vol5)) 倍却涨不动，冲高乏力"
                ))
            }
        }

        // ── 卖 3：放量跌破日内低点 ──
        if pts.count >= 20 {
            let prevLow = pts[0..<lastIdx].map(\.price).min() ?? 0
            if prevLow > 0, last.price < prevLow * 0.999, vol5 >= 1.3 {
                out.append(IntradayTrigger(
                    kind: .breakdownLow, direction: .sell,
                    price: last.price, time: last.time, index: lastIdx,
                    strength: 68,
                    reason: "放量 \(Fmt.price(vol5)) 倍跌破日内低点 \(Fmt.price(prevLow))，现价 \(Fmt.price(last.price))"
                ))
            }
        }

        return out.sorted { $0.strength > $1.strength }
    }
}

// MARK: - 日内支撑压力

/// 日内支撑/压力：把日内证据（日内高低点、均价线、昨收）与
/// 日线最近支撑/压力（`LevelEngine` 结果，由调用方传入）合并，
/// 取离现价最近的一档。日线引擎口径不动，这里只做合并与取最近。
struct IntradayLevels {
    var price: Double
    var support: Double?
    var supportSource: String?
    var resistance: Double?
    var resistanceSource: String?
    /// 现价距支撑的百分比（正数表示支撑在下方）
    var distanceToSupportPct: Double?
    /// 现价距压力的百分比（正数表示压力在上方）
    var distanceToResistancePct: Double?

    static func compute(intraday: IntradayData,
                        dailySupport: Double?,
                        dailyResistance: Double?) -> IntradayLevels {
        let price = intraday.lastPrice
        guard price > 0 else {
            return IntradayLevels(price: 0, support: nil, supportSource: nil,
                                  resistance: nil, resistanceSource: nil,
                                  distanceToSupportPct: nil, distanceToResistancePct: nil)
        }
        let lastAvg = intraday.points.last?.avgPrice ?? 0
        let prev = intraday.previousClose

        // 支撑候选：低于现价的价位，取最高者
        var supports: [(price: Double, source: String)] = []
        if intraday.dayLow > 0, intraday.dayLow < price {
            supports.append((intraday.dayLow, "日内低点"))
        }
        if lastAvg > 0, lastAvg < price {
            supports.append((lastAvg, "均价线"))
        }
        if prev > 0, prev < price {
            supports.append((prev, "昨日收盘"))
        }
        if let ds = dailySupport, ds > 0, ds < price {
            supports.append((ds, "日线支撑"))
        }
        let nearestSupport = supports.max { $0.price < $1.price }

        // 压力候选：高于现价的价位，取最低者
        var resistances: [(price: Double, source: String)] = []
        if intraday.dayHigh > 0, intraday.dayHigh > price {
            resistances.append((intraday.dayHigh, "日内高点"))
        }
        if lastAvg > 0, lastAvg > price {
            resistances.append((lastAvg, "均价线"))
        }
        if prev > 0, prev > price {
            resistances.append((prev, "昨日收盘"))
        }
        if let dr = dailyResistance, dr > 0, dr > price {
            resistances.append((dr, "日线压力"))
        }
        let nearestResistance = resistances.min { $0.price < $1.price }

        return IntradayLevels(
            price: price,
            support: nearestSupport?.price,
            supportSource: nearestSupport?.source,
            resistance: nearestResistance?.price,
            resistanceSource: nearestResistance?.source,
            distanceToSupportPct: nearestSupport.map { (price - $0.price) / price * 100 },
            distanceToResistancePct: nearestResistance.map { ($0.price - price) / price * 100 }
        )
    }
}

// MARK: - 买点榜条目

/// 实时买点榜的一行：一次分时触发 + 日内支撑 + 日线背景。
/// `id` 由标的 + 触发类型构成，榜单层用它跨轮次识别“同一触发”，
/// 从而记录首次出现时间（`firstSeenAt`）并高亮新触发。
struct BuyPointEntry: Identifiable, Hashable {
    var security: Security
    var price: Double
    var changePct: Double
    var trigger: IntradayTrigger
    var firstSeenAt: Date
    var support: Double?
    var resistance: Double?
    var distanceToSupportPct: Double?
    /// 最近一次日线扫描的结论（无扫描结果时为空，不阻塞榜单）
    var dailyGrade: ScanGrade?
    var opportunityScore: Double?

    var id: String { "\(security.id)|\(trigger.kind.rawValue)" }

    /// 10 分钟内首次出现的触发算“新触发”，榜单置顶并高亮
    var isNew: Bool { Date().timeIntervalSince(firstSeenAt) < 600 }
}
