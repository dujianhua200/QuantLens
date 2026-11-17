import Foundation

// MARK: - 预计算上下文

/// 把一只股票的全部指标一次性算好，供逐根K线评估信号使用。
/// 所有数组与 `candles` 等长且下标对齐。
struct MarketContext {
    let candles: [Candle]
    let closes: [Double]
    let volumes: [Double]

    let ma5: [Double]
    let ma10: [Double]
    let ma20: [Double]
    let ma60: [Double]
    let ma120: [Double]

    let macd: Indicators.MACD
    let rsi6: [Double]
    let rsi14: [Double]
    let kdj: Indicators.KDJ
    let boll: Indicators.Bollinger
    let atr: [Double]
    let obv: [Double]
    let cmf: [Double]
    let volRatio: [Double]
    let volMA5: [Double]
    let volMA20: [Double]

    let levels: [PriceLevel]
    let trend: TrendStructure?
    let fundFlowToday: FundFlow?
    let fundFlowHistory: [FundFlow]

    var count: Int { candles.count }
    var lastIndex: Int { candles.count - 1 }
    var currentPrice: Double { candles.last?.close ?? 0 }

    static func build(from data: StockData, extraPeriodScale: Double = 1.0) -> MarketContext {
        let candles = data.candles
        let closes = candles.map(\.close)
        let volumes = candles.map(\.volume)
        let scale = { (p: Int) in max(3, Int((Double(p) * extraPeriodScale).rounded())) }

        return MarketContext(
            candles: candles,
            closes: closes,
            volumes: volumes,
            ma5: Indicators.sma(closes, period: scale(5)),
            ma10: Indicators.sma(closes, period: scale(10)),
            ma20: Indicators.sma(closes, period: scale(20)),
            ma60: Indicators.sma(closes, period: scale(60)),
            ma120: Indicators.sma(closes, period: scale(120)),
            macd: Indicators.macd(closes),
            rsi6: Indicators.rsi(closes, period: scale(6)),
            rsi14: Indicators.rsi(closes, period: scale(14)),
            kdj: Indicators.kdj(candles, period: max(3, Int(9 * extraPeriodScale))),
            boll: Indicators.bollinger(closes, period: scale(20)),
            atr: Indicators.atr(candles, period: scale(14)),
            obv: Indicators.obv(candles),
            cmf: Indicators.cmf(candles, period: scale(20)),
            volRatio: Indicators.volumeRatio(candles, period: scale(20)),
            volMA5: Indicators.sma(volumes, period: 5),
            volMA20: Indicators.sma(volumes, period: scale(20)),
            levels: LevelEngine.detect(candles: candles),
            trend: TrendEngine.analyze(candles: candles),
            fundFlowToday: data.fundFlow,
            fundFlowHistory: data.fundFlowHistory
        )
    }
}

// MARK: - 单根K线的评估结果

struct SignalBundle {
    var score: Double = 0
    var reasons: [String] = []

    mutating func add(_ weight: Double, _ reason: String) {
        score += weight
        reasons.append(reason)
    }

    mutating func subtract(_ weight: Double, _ reason: String) {
        score -= weight
        reasons.append(reason)
    }

    mutating func finalize() {
        score = max(0, min(100, score))
    }
}

struct BarEvaluation {
    var buy = SignalBundle()
    var risk = SignalBundle()
    var accumulate = SignalBundle()
    var distribute = SignalBundle()

    func bundle(for kind: SignalKind) -> SignalBundle {
        switch kind {
        case .buy: return buy
        case .risk: return risk
        case .accumulate: return accumulate
        case .distribute: return distribute
        }
    }
}

// MARK: - 信号引擎

enum SignalEngine {

    /// 评估第 index 根K线上的四类信号强度
    static func evaluate(_ ctx: MarketContext, at index: Int) -> BarEvaluation {
        var e = BarEvaluation()
        guard index >= 30, index < ctx.count else { return e }

        let c = ctx.candles[index]
        let closes = ctx.closes
        let vols = ctx.volumes

        // ---- 通用量能参考 ----
        let volMA5 = ctx.volMA5.value(index) ?? c.volume
        let volMA20 = ctx.volMA20.value(index) ?? c.volume
        let volX = volMA5 > 0 ? c.volume / volMA5 : 1
        let ma20 = ctx.ma20.value(index)
        let ma60 = ctx.ma60.value(index)
        let ma5 = ctx.ma5.value(index)
        let ma10 = ctx.ma10.value(index)

        let dif = ctx.macd.dif.value(index)
        let dea = ctx.macd.dea.value(index)
        let prevDif = ctx.macd.dif.value(index - 1)
        let prevDea = ctx.macd.dea.value(index - 1)
        let hist = ctx.macd.hist.value(index)
        let prevHist = ctx.macd.hist.value(index - 1)

        let rsi6 = ctx.rsi6.value(index) ?? 50
        let rsi14 = ctx.rsi14.value(index) ?? 50
        let prevRsi14 = ctx.rsi14.value(index - 1) ?? 50
        let prevRsi6 = ctx.rsi6.value(index - 1) ?? 50

        let k = ctx.kdj.k.value(index) ?? 50
        let d = ctx.kdj.d.value(index) ?? 50
        let prevK = ctx.kdj.k.value(index - 1) ?? 50
        let prevD = ctx.kdj.d.value(index - 1) ?? 50

        let bollUpper = ctx.boll.upper.value(index)
        let bollLower = ctx.boll.lower.value(index)
        let bollMid = ctx.boll.mid.value(index)
        let bandwidth = ctx.boll.bandwidth.value(index) ?? 5

        let trend = ctx.trend
        let pctRank = Indicators.percentileRank(closes, index: index, lookback: 120)
        let priceSlope20 = Indicators.slopePercent(closes, index: index, period: 20)
        let streak = Indicators.streak(closes)

        let nearestSupport = ctx.levels.filter { $0.price <= c.close }.max { $0.price < $1.price }
        let nearestResistance = ctx.levels.filter { $0.price > c.close }.min { $0.price < $1.price }

        // ================= 买入 =================
        if let ma20, c.close > ma20, let trend, trend.direction.isBullish {
            e.buy.add(10, "价格站上20日均线且中期趋势向上（\(trend.direction.label)）")
        }
        if let ma20, let ma60, ma20 > ma60, c.close > ma5 ?? c.close {
            e.buy.add(6, "均线多头排列，5日线上方运行")
        }

        // 回踩支撑缩量
        if let s = nearestSupport {
            let distToSupport = abs(c.low - s.price) / s.price
            if distToSupport < 0.015, c.close > c.open, c.close > s.price, volX < 0.85, s.score >= 45 {
                e.buy.add(14, "回踩\(s.strengthLabel)支撑 \(Fmt.price(s.price)) 不破，缩量收阳（量能仅 \(Fmt.price(volX)) 倍）")
            }
        }

        // MACD 金叉
        if let dif, let dea, let prevDif, let prevDea, prevDif <= prevDea, dif > dea {
            e.buy.add(12, "MACD 金叉（DIF 上穿 DEA）")
            if dif < 0 { e.buy.add(5, "金叉发生在零轴下方，属底部反转修复") }
        }

        // RSI 超卖回升
        if rsi14 < 35, rsi14 > prevRsi14, prevRsi14 <= 38 {
            e.buy.add(10, "RSI(14) 在 \(Fmt.price(rsi14, decimals: 1)) 低位拐头向上")
        }

        // KDJ 低位金叉
        if prevK <= prevD, k > d, k < 32 {
            e.buy.add(10, "KDJ 在低位（K=\(Fmt.price(k, decimals: 1))）金叉")
        }

        // 布林下轨
        if let bollLower, c.low <= bollLower * 1.005, c.close > bollLower {
            e.buy.add(8, "触及布林下轨后收回，超跌反抽")
        }
        // 布林极度收口后的突破
        if bandwidth < 5, let bollUpper, c.close > bollUpper {
            e.buy.add(9, "布林带极度收口后向上突破，波动率扩张")
        }

        // 放量突破压力
        if let r = nearestResistance, c.close > r.price * 1.004, volX > 1.4, r.score >= 40 {
            e.buy.add(16, "放量 \(Fmt.price(volX)) 倍突破\(r.strengthLabel)压力位 \(Fmt.price(r.price))")
        }

        // 底部首阳
        var downDays = 0
        var j = index - 1
        while j > 0, closes[j] < closes[j - 1], index - j < 8 {
            downDays += 1
            j -= 1
        }
        if downDays >= 4, c.close > c.open, volX > 1.35, c.closePosition > 0.6 {
            e.buy.add(13, "连跌 \(downDays) 日后放量首根阳线，收盘位于当日高位")
        }

        // 底背离
        if let divergence = bullishDivergence(ctx, index: index) {
            e.buy.add(16, divergence)
        }

        // 温和放量
        if let vr = ctx.volRatio.value(index), vr > 1.15, vr < 2.6, c.close > c.open, c.close > (ma5 ?? c.close) {
            e.buy.add(6, "温和放量（量比 \(Fmt.price(vr))）推动价格上行")
        }

        // 主力进场时同步给买入加成
        // 强下跌趋势下压制买点
        if let trend, trend.direction == .strongDown {
            e.buy.subtract(14, "中期趋势仍处弱势下跌，买点需等待趋势修复")
        }

        // ================= 风险 =================
        if rsi6 > 82 || rsi14 > 78 {
            e.risk.add(11, "RSI 进入超买区（RSI6=\(Fmt.price(rsi6, decimals: 1))，RSI14=\(Fmt.price(rsi14, decimals: 1))）")
        }
        if let ma20 {
            let dev = (c.close / ma20 - 1) * 100
            if dev > 12 {
                e.risk.add(13, "价格偏离20日均线 \(Fmt.pct(dev))，短线均值回归压力大")
            } else if dev > 8 {
                e.risk.add(7, "价格偏离20日均线 \(Fmt.pct(dev))，短期涨幅偏快")
            }
        }
        if streak >= 5 {
            e.risk.add(8, "已连续上涨 \(streak) 个交易日，短线获利盘丰厚")
        }
        if let bollUpper, c.high >= bollUpper * 0.998, volX < 0.9 {
            e.risk.add(10, "触及布林上轨但量能萎缩，上攻动能不足")
        }
        if let dif, let dea, let prevDif, let prevDea, prevDif >= prevDea, dif < dea, let hist, let prevHist, prevHist > 0 {
            e.risk.add(13, "MACD 高位死叉，红柱缩短转绿")
        }
        if let divergence = bearishDivergence(ctx, index: index) {
            e.risk.add(18, divergence)
        }
        if let r = nearestResistance {
            let dist = (r.price - c.close) / c.close
            if dist < 0.018, r.score >= 50, volX > 1.3, c.upperShadowRatio > 0.35 {
                e.risk.add(14, "逼近\(r.strengthLabel)压力位 \(Fmt.price(r.price)) 放量滞涨，上影线明显")
            } else if dist < 0.012, r.score >= 60 {
                e.risk.add(8, "上方 \(Fmt.pct(dist * 100)) 处有\(r.strengthLabel)压力位 \(Fmt.price(r.price))")
            }
        }
        if c.upperShadowRatio > 0.55, volX > 1.8 {
            e.risk.add(12, "巨量长上影线（上影占振幅 \(Fmt.price(c.upperShadowRatio * 100, decimals: 0))%），冲高遇阻")
        }
        if let ma20, c.close < ma20, volX > 1.4, closes[index - 1] >= ma20 {
            e.risk.add(15, "放量跌破20日均线，短线转弱")
        }
        // 高位十字星 / 滞涨
        if c.bodyRatio < 0.15, pctRank > 70, volX > 1.6 {
            e.risk.add(8, "高位十字星伴随放量，多空分歧加剧")
        }
        // 量价背离
        if priceSlope20 > 3, let vr = ctx.volRatio.value(index), vr < 0.75 {
            e.risk.add(10, "近20日价格上行但成交量持续萎缩，量价背离")
        }
        // 单日暴涨后回收
        let bodyPct = c.open > 0 ? (c.close - c.open) / c.open * 100 : 0
        let highPct = c.open > 0 ? (c.high - c.open) / c.open * 100 : 0
        if highPct > 6, bodyPct < highPct * 0.4 {
            e.risk.add(9, "盘中冲高 \(Fmt.pct(highPct)) 后回落，收盘仅 \(Fmt.pct(bodyPct))，冲高回落")
        }

        // ================= 主力进场 =================
        // OBV 与价格背离（吸筹）
        if let obvNow = ctx.obv.value(index), let obvPrev = ctx.obv.value(index - 15), obvPrev != 0 {
            let obvChange = (obvNow - obvPrev) / max(abs(obvPrev), 1)
            if obvChange > 0.08, priceSlope20 < 0.35, priceSlope20 > -1.2 {
                e.accumulate.add(16, "OBV 逆势抬升（+\(Fmt.pct(obvChange * 100, decimals: 1))）而价格横盘，典型吸筹特征")
            }
        }
        if let cmf = ctx.cmf.value(index) {
            if cmf > 0.18 {
                e.accumulate.add(14, "CMF 资金流量 \(Fmt.price(cmf))，持续净流入")
            } else if cmf > 0.08 {
                e.accumulate.add(7, "CMF 资金流量 \(Fmt.price(cmf))，温和流入")
            }
        }
        // 长下影护盘
        var longLowerCount = 0
        for x in max(0, index - 9)...index {
            let cc = ctx.candles[x]
            if cc.lowerShadowRatio > 0.45, cc.bodyRatio < 0.5 { longLowerCount += 1 }
        }
        if longLowerCount >= 3 {
            e.accumulate.add(12, "近10根K线出现 \(longLowerCount) 次长下影，下方承接积极")
        }
        // 缩量止跌后首放量
        if index >= 6 {
            let prev5Vol = (0..<5).map { vols[index - 1 - $0] }.reduce(0, +) / 5
            let prev5Ranges = (0..<5).map { ctx.candles[index - 1 - $0].range / ctx.candles[index - 1 - $0].close }
            let prev5Range = prev5Ranges.reduce(0, +) / 5
            if prev5Vol < volMA20 * 0.75, c.volume > prev5Vol * 1.8, c.close > c.open, prev5Range < 0.035 {
                e.accumulate.add(16, "窄幅缩量整理后首次显著放量收阳，资金入场")
            }
        }
        // 资金流历史
        if ctx.fundFlowHistory.count >= 3 {
            let recent = Array(ctx.fundFlowHistory.suffix(3))
            let allIn = recent.allSatisfy { $0.mainNet > 0 }
            let sum = recent.map(\.mainNet).reduce(0, +)
            if allIn, sum > 0 {
                e.accumulate.add(18, "主力资金连续3日净流入，累计 \(Fmt.money(sum))")
            }
        }
        if let ff = ctx.fundFlowToday, ff.mainNet > 0, ff.mainRatio > 3 {
            e.accumulate.add(10, "当日主力净流入 \(Fmt.money(ff.mainNet))，占比 \(Fmt.pct(ff.mainRatio))")
        }
        // 上涨日量能 > 下跌日量能
        if index >= 20 {
            var upVol = 0.0, downVol = 0.0
            for x in (index - 19)...index {
                if closes[x] >= ctx.candles[x].open { upVol += vols[x] } else { downVol += vols[x] }
            }
            if downVol > 0, upVol > downVol * 1.4 {
                e.accumulate.add(12, "近20日上涨日成交量为下跌日的 \(Fmt.price(upVol / downVol)) 倍，多方主导")
            }
        }
        // 低位温和放量
        if pctRank < 32, let vr = ctx.volRatio.value(index), vr > 1.1, vr < 2.2, c.close > c.open {
            e.accumulate.add(10, "价格处近120日 \(Fmt.price(pctRank, decimals: 0))% 低分位，量比 \(Fmt.price(vr)) 温和放大")
        }
        // 阳线占比
        if index >= 20 {
            let upBars = ((index - 19)...index).filter { ctx.candles[$0].close >= ctx.candles[$0].open }.count
            if upBars >= 13 {
                e.accumulate.add(9, "近20根K线中 \(upBars) 根收阳，多头蓄势")
            }
        }

        // ================= 主力撤退 =================
        if let obvNow = ctx.obv.value(index), let obvPrev = ctx.obv.value(index - 15), obvPrev != 0 {
            let obvChange = (obvNow - obvPrev) / max(abs(obvPrev), 1)
            if obvChange < -0.08, priceSlope20 > -0.35 {
                e.distribute.add(18, "OBV 持续下滑（\(Fmt.pct(obvChange * 100, decimals: 1))）而价格未跌，资金暗中流出")
            }
        }
        if let cmf = ctx.cmf.value(index) {
            if cmf < -0.18 {
                e.distribute.add(14, "CMF 资金流量 \(Fmt.price(cmf))，持续净流出")
            } else if cmf < -0.08 {
                e.distribute.add(7, "CMF 资金流量 \(Fmt.price(cmf))，温和流出")
            }
        }
        // 高位长上影
        var longUpperCount = 0
        for x in max(0, index - 9)...index {
            let cc = ctx.candles[x]
            if cc.upperShadowRatio > 0.5, cc.bodyRatio < 0.45 { longUpperCount += 1 }
        }
        if longUpperCount >= 3, pctRank > 55 {
            e.distribute.add(14, "高位区连续 \(longUpperCount) 根长上影，上方抛压沉重")
        }
        // 涨缩量、跌放量
        if index >= 20 {
            var upVol = 0.0, downVol = 0.0
            for x in (index - 19)...index {
                if closes[x] >= ctx.candles[x].open { upVol += vols[x] } else { downVol += vols[x] }
            }
            if upVol > 0, downVol > upVol * 1.4 {
                e.distribute.add(16, "近20日下跌日成交量为上涨日的 \(Fmt.price(downVol / upVol)) 倍，出货特征")
            }
        }
        if ctx.fundFlowHistory.count >= 3 {
            let recent = Array(ctx.fundFlowHistory.suffix(3))
            let allOut = recent.allSatisfy { $0.mainNet < 0 }
            let sum = recent.map(\.mainNet).reduce(0, +)
            if allOut, sum < 0 {
                e.distribute.add(18, "主力资金连续3日净流出，累计 \(Fmt.money(sum))")
            }
        }
        if let ff = ctx.fundFlowToday, ff.mainNet < 0, ff.mainRatio < -3 {
            e.distribute.add(10, "当日主力净流出 \(Fmt.money(ff.mainNet))，占比 \(Fmt.pct(ff.mainRatio))")
        }
        // 高位缩量
        if pctRank > 78, let vr = ctx.volRatio.value(index), vr < 0.8, c.close > c.open {
            e.distribute.add(12, "价格处近120日 \(Fmt.price(pctRank, decimals: 0))% 高分位但量比仅 \(Fmt.price(vr))，无量上涨")
        }
        // 放量长阴
        if c.close < c.open, c.bodyRatio > 0.6, volX > 1.8, pctRank > 50 {
            e.distribute.add(14, "高位放量长阴（实体占振幅 \(Fmt.price(c.bodyRatio * 100, decimals: 0))%），承接乏力")
        }
        // 阴线居多
        if index >= 20 {
            let downBars = ((index - 19)...index).filter { ctx.candles[$0].close < ctx.candles[$0].open }.count
            if downBars >= 13 {
                e.distribute.add(10, "近20根K线中 \(downBars) 根收阴，重心下移")
            }
        }

        // 交叉压制：主力撤退显著时，买入评分打折
        e.buy.finalize()
        e.risk.finalize()
        e.accumulate.finalize()
        e.distribute.finalize()

        if e.distribute.score >= 60 {
            e.buy.score = max(0, e.buy.score - 18)
            e.risk.score = min(100, e.risk.score + 8)
        }
        if e.accumulate.score >= 60 {
            e.buy.score = min(100, e.buy.score + 6)
        }
        if e.buy.score >= 60 {
            e.risk.score = max(0, e.risk.score - 6)
        }

        return e
    }

    // MARK: - 背离检测

    private static func bullishDivergence(_ ctx: MarketContext, index: Int) -> String? {
        let window = 30
        guard index > window else { return nil }
        let start = index - window
        let slice = Array(ctx.candles[start...index])
        guard let recentLow = slice.suffix(8).map(\.low).min() else { return nil }

        // 找区间内较早的低点
        var priorLow = Double.greatestFiniteMagnitude
        var priorIdx = -1
        for i in start...(index - 8) {
            let v = ctx.candles[i].low
            if v < priorLow { priorLow = v; priorIdx = i }
        }
        guard priorIdx >= 0, recentLow < priorLow else { return nil }

        // 价格新低，但 MACD / RSI 未新低
        if let curDif = ctx.macd.hist.value(index), let prevDif = ctx.macd.hist.value(priorIdx),
           curDif > prevDif, let curR = ctx.rsi14.value(index), let prevR = ctx.rsi14.value(priorIdx),
           curR > prevR + 1.5 {
            return "底背离：价格创阶段新低 \(Fmt.price(recentLow))，但 MACD 与 RSI 均抬高"
        }
        return nil
    }

    private static func bearishDivergence(_ ctx: MarketContext, index: Int) -> String? {
        let window = 30
        guard index > window else { return nil }
        let start = index - window
        let slice = Array(ctx.candles[start...index])
        guard let recentHigh = slice.suffix(8).map(\.high).max() else { return nil }

        var priorHigh = -Double.greatestFiniteMagnitude
        var priorIdx = -1
        for i in start...(index - 8) {
            let v = ctx.candles[i].high
            if v > priorHigh { priorHigh = v; priorIdx = i }
        }
        guard priorIdx >= 0, recentHigh > priorHigh else { return nil }

        if let curDif = ctx.macd.dif.value(index), let prevDif = ctx.macd.dif.value(priorIdx),
           curDif < prevDif, let curR = ctx.rsi14.value(index), let prevR = ctx.rsi14.value(priorIdx),
           curR < prevR - 1.5 {
            return "顶背离：价格创阶段新高 \(Fmt.price(recentHigh))，但 MACD 与 RSI 同步走低"
        }
        return nil
    }

    // MARK: - 汇总分析

    static func analyze(data: StockData, period: KPeriod, gates: TradePointGates = .unknown) -> Analysis {
        let scale = period.isIntraday ? 1.0 : (period == .day ? 1.0 : (period == .week ? 1.6 : 2.2))
        let ctx = MarketContext.build(from: data, extraPeriodScale: period.isIntraday ? 1.0 : scale)
        guard ctx.count >= 40 else {
            return Analysis(context: ctx, signals: [], markers: [], summary: "K线数量不足，无法分析（需要至少40根）", eval: BarEvaluation())
        }

        let eval = evaluate(ctx, at: ctx.lastIndex)
        let last = ctx.lastIndex
        let price = ctx.currentPrice
        let date = ctx.candles[last].date
        // 恐惧/贪婪日线信号：独立计算，不改动四类信号分数
        let fearSignals = FearSignals.evaluate(ctx, at: last, limitUp: data.security.market.limitUp)

        var signals: [TradingSignal] = []
        for kind in SignalKind.allCases {
            let b = eval.bundle(for: kind)
            guard b.score >= 45 else { continue }
            signals.append(TradingSignal(
                kind: kind,
                score: b.score,
                title: b.reasons.first ?? kind.label,
                reasons: b.reasons,
                price: price,
                date: date,
                period: period
            ))
        }
        signals.sort { $0.kind.priority < $1.kind.priority }

        // 历史标记（用于图上打点）
        //
        // 采用「事件触发」而非「分数峰值」：只在评分自下向上穿越阈值的那一刻打点。
        // 分数峰值法在评分平台期会逐根通过判定，导致满屏标记；事件法天然稀疏。
        let markThreshold = 70.0
        let cooldown = period.isIntraday ? 18 : (period == .day ? 8 : 5)
        var markers: [TradingSignal] = []
        var lastMarked: [SignalKind: Int] = [:]
        var armed: [SignalKind: Bool] = [:]
        for kind in SignalKind.allCases { armed[kind] = false }

        // 预计算全序列评分，避免 O(n²) 重复评估
        let from = max(40, ctx.count - 260)
        var scores: [Int: [SignalKind: Double]] = [:]
        for i in from..<ctx.count {
            let ev = evaluate(ctx, at: i)
            var row: [SignalKind: Double] = [:]
            for kind in SignalKind.allCases { row[kind] = ev.bundle(for: kind).score }
            scores[i] = row
        }

        for i in from..<ctx.count {
            guard let row = scores[i] else { continue }
            for kind in SignalKind.allCases {
                let s = row[kind] ?? 0
                // 回落则重新武装，等待下一次上穿
                if s < markThreshold - 12 {
                    armed[kind] = true
                    continue
                }
                guard armed[kind] == true, s >= markThreshold else { continue }
                if let prev = lastMarked[kind], i - prev < cooldown { continue }
                let ev = evaluate(ctx, at: i).bundle(for: kind)
                markers.append(TradingSignal(
                    kind: kind,
                    score: s,
                    title: ev.reasons.first ?? kind.label,
                    reasons: ev.reasons,
                    price: ctx.candles[i].close,
                    date: ctx.candles[i].date,
                    period: period
                ))
                lastMarked[kind] = i
                armed[kind] = false
            }
        }

        // 显式买卖点引擎：替换旧标记系统作为图上打点与面板列表的主来源。
        // 旧 markers 保留计算（扫描/回测仍引用），但图上优先画买卖点。
        let engineResult = TradePointEngine.evaluateAll(
            ctx: ctx, from: from, limitUp: data.security.market.limitUp, gates: gates
        )

        let summary = makeSummary(ctx: ctx, eval: eval, signals: signals)
        return Analysis(context: ctx, signals: signals, markers: markers, summary: summary, eval: eval,
                        fearSignals: fearSignals,
                        tradePoints: engineResult.points,
                        fearHistory: engineResult.fearHistory)
    }

    private static func makeSummary(ctx: MarketContext, eval: BarEvaluation, signals: [TradingSignal]) -> String {
        var parts: [String] = []
        if let trend = ctx.trend {
            parts.append("趋势：\(trend.direction.label)（强度 \(Fmt.price(trend.strength, decimals: 0))）")
        }
        let buy = eval.buy.score, risk = eval.risk.score
        let acc = eval.accumulate.score, dist = eval.distribute.score

        if risk >= 65 {
            parts.append("短线风险偏高，不宜追高")
        } else if buy >= 65 {
            parts.append("出现较明确买点，可分批参与")
        } else if buy >= 45 {
            parts.append("结构性机会，等待确认")
        } else {
            parts.append("暂无明确方向性机会")
        }
        if acc >= 60, acc > dist {
            parts.append("资金呈流入特征")
        } else if dist >= 60, dist > acc {
            parts.append("资金呈流出特征")
        }
        if let s = ctx.levels.filter({ $0.kind == .support }).max(by: { $0.price < $1.price }) {
            parts.append("下方关键支撑 \(Fmt.price(s.price))")
        }
        if let r = ctx.levels.filter({ $0.kind == .resistance }).min(by: { $0.price < $1.price }) {
            parts.append("上方关键压力 \(Fmt.price(r.price))")
        }
        return parts.joined(separator: "；")
    }
}

// MARK: - 分析结果

struct Analysis {
    var context: MarketContext
    var signals: [TradingSignal]
    var markers: [TradingSignal]
    var summary: String
    var eval: BarEvaluation
    /// 恐惧/贪婪日线信号（独立于四类信号，供信号面板与机会榜展示）
    var fearSignals: [FearSignal] = []
    /// 显式买卖点（新引擎，图上打点与面板列表的主来源）
    var tradePoints: [TradePointSignal] = []
    /// 逐根恐惧/贪婪信号历史（图上叠加展示用）
    var fearHistory: [FearSignal] = []

    var supports: [PriceLevel] { context.levels.filter { $0.kind == .support } }
    var resistances: [PriceLevel] { context.levels.filter { $0.kind == .resistance } }
}
