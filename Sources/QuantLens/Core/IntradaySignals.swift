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
    case panicVReversal    // 恐慌杀跌后 V 型反转
    case secondDipHigher   // 二次回踩确认（踩点抬高）
    case avgLineBreakout   // 均价线上横盘突破
    case volumePriceAccel  // 量价齐升加速
    case lateRush          // 尾盘抢筹

    var label: String {
        switch self {
        case .dipToAverage: return "回踩均价"
        case .breakoutHigh: return "突破新高"
        case .volumeSurge: return "放量上攻"
        case .belowAverageWeak: return "均线下弱势"
        case .stalledHigh: return "高位滞涨"
        case .breakdownLow: return "跌破新低"
        case .panicVReversal: return "V型反转"
        case .secondDipHigher: return "二次回踩"
        case .avgLineBreakout: return "横盘突破"
        case .volumePriceAccel: return "量价加速"
        case .lateRush: return "尾盘抢筹"
        }
    }

    var direction: TradeDirection {
        switch self {
        case .dipToAverage, .breakoutHigh, .volumeSurge: return .buy
        case .belowAverageWeak, .stalledHigh, .breakdownLow: return .sell
        case .panicVReversal, .secondDipHigher, .avgLineBreakout, .volumePriceAccel, .lateRush: return .buy
        }
    }

    /// 触发背后的主导心理（与 FearSignals 的 SentimentTag 同口径）。
    var sentiment: SentimentTag {
        switch self {
        case .dipToAverage, .belowAverageWeak, .breakdownLow: return .fear
        case .panicVReversal, .secondDipHigher: return .fear
        case .breakoutHigh, .volumeSurge, .stalledHigh: return .greed
        case .volumePriceAccel, .lateRush: return .greed
        case .avgLineBreakout: return .neutral
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

    /// 情绪标签（由触发类型决定，与日线恐惧/贪婪信号同口径）
    var sentiment: SentimentTag { kind.sentiment }
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
                    // 踩点取跌幅最深的那一分钟（与 dipDepth / dipLow 同一点），
                    // 而不是最后一个在均价线下方的点
                    let depth = (p.avgPrice - p.price) / p.avgPrice
                    if depth > dipDepth {
                        dipDepth = depth
                        dipIndex = i
                    }
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

        // ── 买 4：恐慌杀跌 V 反 ──
        // 过去 6 分钟内急跌超 1.5% 后快速收回均价线上方，且相对低点回升超 0.8%。
        // 杀跌段缩量说明恐慌抛盘衰竭，加分。
        if pts.count >= 15 {
            let startIdx = lastIdx - 5
            let startPrice = pts[startIdx].price
            var minPrice = startPrice
            var minIdx = startIdx
            for i in startIdx...lastIdx {
                let p = pts[i].price
                if p < minPrice {
                    minPrice = p
                    minIdx = i
                }
            }
            let dropPct = startPrice > 0 ? (minPrice / startPrice - 1) * 100 : 0
            let recoveredAboveAvg = last.price >= last.avgPrice
            let bounced = last.price > minPrice * 1.008
            if dropPct <= -1.5, minIdx < lastIdx, recoveredAboveAvg, bounced {
                var dropVolSum = 0.0
                var dropCount = 0
                for i in (startIdx + 1)...minIdx {
                    dropVolSum += pts[i].volume
                    dropCount += 1
                }
                let dropAvg = dropCount > 0 ? dropVolSum / Double(dropCount) : 0
                let contracted = avgVol > 0 && dropAvg < avgVol * 0.9
                var strength = 70.0
                if contracted { strength += 8 }
                var reason = "5 分钟急跌 \(Fmt.pct(dropPct, decimals: 1)) 后快速收回均价线，"
                    + "恐慌杀跌衰竭、V 型反转"
                if contracted { reason += "，杀跌段缩量" }
                out.append(IntradayTrigger(
                    kind: .panicVReversal, direction: .buy,
                    price: last.price, time: last.time, index: lastIdx,
                    strength: strength, reason: reason
                ))
            }
        }

        // ── 买 5：二次回踩确认 ──
        // 过去 25 分钟内出现两次独立的“跌破均价后收回”过程（两次之间至少 3 分钟
        // 收在均价线上方才算独立），且第二次踩点高于第一次：恐慌抛压一次比一次弱。
        if pts.count >= 25 {
            let windowStart = lastIdx - 24
            // 先标出每分钟是否在均价线下方
            var below: [Bool] = []
            for i in windowStart...lastIdx {
                let p = pts[i]
                below.append(p.avgPrice > 0 && p.price < p.avgPrice)
            }
            // 找“跌破—收回”片段：下方连续段 + 其后至少 3 分钟在上方
            struct DipEpisode {
                var low: Double
                var lowVolume: Double
            }
            var episodes: [DipEpisode] = []
            var i = 0
            while i < below.count {
                if !below[i] {
                    i += 1
                    continue
                }
                // 一段连续的下方分钟
                var segLow = Double.greatestFiniteMagnitude
                var segLowVol = 0.0
                var j = i
                while j < below.count, below[j] {
                    let p = pts[windowStart + j]
                    if p.price < segLow {
                        segLow = p.price
                        segLowVol = p.volume
                    }
                    j += 1
                }
                // 其后上方分钟数
                var aboveCount = 0
                var k = j
                while k < below.count, !below[k] {
                    aboveCount += 1
                    k += 1
                }
                if aboveCount >= 3 {
                    episodes.append(DipEpisode(low: segLow, lowVolume: segLowVol))
                }
                i = j
            }
            if episodes.count >= 2 {
                let first = episodes[episodes.count - 2]
                let second = episodes[episodes.count - 1]
                let higher = second.low > first.low * 1.001
                let aboveNow = last.price >= last.avgPrice
                if higher, aboveNow {
                    var strength = 68.0
                    if second.lowVolume < first.lowVolume { strength += 6 }
                    let reason = "二次回踩均价线，踩点由 \(Fmt.price(first.low)) 抬高至 \(Fmt.price(second.low))，"
                        + "恐慌抛压一次比一次弱"
                    out.append(IntradayTrigger(
                        kind: .secondDipHigher, direction: .buy,
                        price: last.price, time: last.time, index: lastIdx,
                        strength: strength, reason: reason
                    ))
                }
            }
        }

        // ── 买 6：均价线上横盘突破 ──
        // 近 15 分钟内有 ≥10 分钟在均价线 ±0.3% 内横盘（横盘段结束于最近 6 分钟内），
        // 随后现价站上均价线 +0.2%~+1.0% 且近 5 分钟量比 ≥1.3。
        // 已大幅拉升（>1%）的不算，避免与“突破新高”重复。
        if pts.count >= 15 {
            let windowStart = max(0, lastIdx - 14)
            var hoverEnd: Int? = nil
            var h = windowStart + 9
            while h <= lastIdx {
                var allHover = true
                for x in (h - 9)...h {
                    let p = pts[x]
                    if p.avgPrice <= 0 {
                        allHover = false
                        break
                    }
                    let dev = abs(p.price - p.avgPrice) / p.avgPrice
                    if dev > 0.003 {
                        allHover = false
                        break
                    }
                }
                if allHover { hoverEnd = h }
                h += 1
            }
            if let he = hoverEnd, he >= lastIdx - 6 {
                let aboveAvg = last.avgPrice > 0 && last.price > last.avgPrice * 1.002
                let notRunaway = last.avgPrice > 0 && last.price <= last.avgPrice * 1.01
                if aboveAvg, notRunaway, vol5 >= 1.3 {
                    let reason = "均价线附近横盘 10 分钟后放量突破，现价站上均价线，"
                        + "多空分歧后选择向上"
                    out.append(IntradayTrigger(
                        kind: .avgLineBreakout, direction: .buy,
                        price: last.price, time: last.time, index: lastIdx,
                        strength: 66, reason: reason
                    ))
                }
            }
        }

        // ── 买 7：量价齐升加速 ──
        // 近 10 分钟价格持续抬升（涨幅 ≥0.8%，后 5 分钟高点高于前 5 分钟高点），
        // 且量能两级加速：前 5 分钟均量已高于全天均量 1.2 倍，后 5 分钟均量再高于
        // 前 5 分钟 1.3 倍；现价未创新高（区别于“突破新高”与“放量上攻”的突然放量）。
        if pts.count >= 20 {
            let firstStart = lastIdx - 9
            let secondStart = lastIdx - 4
            var firstVolSum = 0.0
            var firstHigh = 0.0
            for x in firstStart...(secondStart - 1) {
                firstVolSum += pts[x].volume
                if pts[x].price > firstHigh { firstHigh = pts[x].price }
            }
            var secondVolSum = 0.0
            var secondHigh = 0.0
            for x in secondStart...lastIdx {
                secondVolSum += pts[x].volume
                if pts[x].price > secondHigh { secondHigh = pts[x].price }
            }
            let firstAvg = firstVolSum / 5
            let secondAvg = secondVolSum / 5
            let basePrice = pts[firstStart].price
            let gain10 = basePrice > 0 ? (last.price / basePrice - 1) * 100 : 0
            var prevHigh = 0.0
            for x in 0..<lastIdx {
                if pts[x].price > prevHigh { prevHigh = pts[x].price }
            }
            let notNewHigh = prevHigh <= 0 || last.price <= prevHigh * 1.001
            let warmFirst = avgVol > 0 && firstAvg >= avgVol * 1.2
            let accelerating = firstAvg > 0 && secondAvg >= firstAvg * 1.3
            if gain10 >= 0.8, secondHigh > firstHigh, warmFirst, accelerating, notNewHigh {
                let reason = "近 10 分钟量价齐升：涨幅 \(Fmt.pct(gain10, decimals: 1))，"
                    + "量能持续加温，买盘层层递进"
                out.append(IntradayTrigger(
                    kind: .volumePriceAccel, direction: .buy,
                    price: last.price, time: last.time, index: lastIdx,
                    strength: 68, reason: reason
                ))
            }
        }

        // ── 买 8：尾盘抢筹 ──
        // 14:45 之后：10 分钟上涨 ≥0.6%，近 5 分钟量比 ≥1.8，现价处日内 80% 高分位。
        // 理由中注明追高风险：尾盘抢筹多为隔夜博弈，次日兑现压力大。
        if pts.count >= 15 {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
            let comp = cal.dateComponents([.hour, .minute], from: last.time)
            let hh = comp.hour ?? 0
            let mm = comp.minute ?? 0
            let mins = hh * 60 + mm
            let isLate = mins >= 14 * 60 + 45 && mins < 15 * 60
            if isLate, let chg = changeVs(minutesAgo: 10), chg >= 0.6, vol5 >= 1.8 {
                var dayPos = 0.0
                if intraday.dayHigh > intraday.dayLow {
                    dayPos = (last.price - intraday.dayLow) / (intraday.dayHigh - intraday.dayLow)
                }
                if dayPos > 0.8 {
                    let reason = "尾盘 10 分钟上涨 \(Fmt.pct(chg, decimals: 1)) 且放量 \(Fmt.price(vol5)) 倍，"
                        + "资金抢筹明显；注意：尾盘追高次日兑现压力大，风险偏高"
                    out.append(IntradayTrigger(
                        kind: .lateRush, direction: .buy,
                        price: last.price, time: last.time, index: lastIdx,
                        strength: 64, reason: reason
                    ))
                }
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
