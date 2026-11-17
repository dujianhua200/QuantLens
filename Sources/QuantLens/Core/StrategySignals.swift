import Foundation

// MARK: - 战法识别（源自公开短线策略的规则化实现）

/// 把公开流传的短线战法，转化为可计算的确定性规则。
///
/// 说明：这里的逻辑来自公开社区分享的选股公式（通达信语法），
/// 已剔除平台专有函数、修正了社区指出的明显笔误，
/// 只保留能在日线/分时数据上稳定复现的部分。
///
/// 覆盖的战法：
/// 1. 五线粘合突破（均线粘合 + 一阳穿多线 + 放量）
/// 2. 尾盘异动（乖离强度 + KDJ + MACD 底部动能 + 温和放量）
/// 3. 涨停回马枪（涨停后回调 + 缩量 + 动能反转）
/// 4. 洗盘终结（急跌 + 缩量企稳 + 放量反攻）
/// 5. MACD 背离（顶背离 / 底背离）
enum StrategySignals {

    /// 单个战法的识别结果
    struct Match: Identifiable {
        let id: String
        /// 战法名称
        var name: String
        /// 是否命中
        var hit: Bool
        /// 强度 0~100
        var strength: Double
        /// 命中说明
        var detail: String
        /// 对买卖方向的建议
        var bias: Bias
        /// 全市场实测超额收益（%），nil 表示未验证
        var verifiedEdge: Double? = nil

        enum Bias { case buy, sell, neutral }
    }

    /// 综合战法评估
    struct Result {
        var matches: [Match]
        /// 战法净偏向：正=买，负=卖
        var netBias: Double
        /// 最强的命中战法
        var strongest: Match?
        /// 摘要
        var summary: String
    }

    // MARK: - 主入口

    /// 对日线数据执行全部战法识别
    static func evaluate(candles: [Candle]) -> Result {
        guard candles.count >= 30 else {
            return Result(matches: [], netBias: 0, strongest: nil, summary: "数据不足")
        }

        var matches: [Match] = [
            fiveLineSqueeze(candles),
            tailSurge(candles),
            limitUpPullback(candles),
            washoutEnd(candles),
            cupHandle(candles),
            macdDivergence(candles)
        ]

        // 净偏向：买 +strength，卖 -strength
        var net = 0.0
        for m in matches where m.hit {
            switch m.bias {
            case .buy: net += m.strength / 100
            case .sell: net -= m.strength / 100
            case .neutral: break
            }
        }

        let hits = matches.filter(\.hit).sorted { $0.strength > $1.strength }
        matches = matches.sorted { ($0.hit ? 1 : 0, $0.strength) > ($1.hit ? 1 : 0, $1.strength) }

        let summary: String
        if let s = hits.first {
            summary = "命中 \(hits.count) 个战法，最强：\(s.name)（\(Int(s.strength))）"
        } else {
            summary = "无战法命中"
        }

        return Result(matches: matches, netBias: net, strongest: hits.first, summary: summary)
    }

    // MARK: - ① 五线粘合突破

    /// 均线粘合到极致后放量突破，是典型的启动信号。
    /// 原公式：五线(5/10/20/30/60)极差 < 收盘价 8% + 一阳穿三线 + 涨幅≥2% + 放量。
    /// 修正：原文「V>HHV(H,10)」把量价比量价，属笔误，改为「量 > 10 日均量 × 1.5」。
    static func fiveLineSqueeze(_ candles: [Candle]) -> Match {
        let closes = candles.map(\.close)
        let n = closes.count
        guard n >= 65 else { return Match(id: "squeeze", name: "五线粘合突破", hit: false, strength: 0, detail: "数据不足", bias: .neutral) }

        let ma5 = Indicators.sma(closes, period: 5)
        let ma10 = Indicators.sma(closes, period: 10)
        let ma20 = Indicators.sma(closes, period: 20)
        let ma30 = Indicators.sma(closes, period: 30)
        let ma60 = Indicators.sma(closes, period: 60)

        let i = n - 1
        guard ma60[i] > 0 else {
            return Match(id: "squeeze", name: "五线粘合突破", hit: false, strength: 0, detail: "均线未就绪", bias: .neutral)
        }

        let values = [ma5[i], ma10[i], ma20[i], ma30[i], ma60[i]]
        let hi = values.max()!, lo = values.min()!
        let close = closes[i]
        let squeezeRatio = (hi - lo) / close

        // 粘合度：< 8% 视为粘合，越小越极致
        let isSqueezed = squeezeRatio < 0.08

        // 一阳穿多线：今日收盘站上 MA5/MA10/MA20，且开盘在均线下方
        let today = candles[i]
        let crossUp = today.open < min(ma5[i], min(ma10[i], ma20[i]))
            && today.close > max(ma5[i], max(ma10[i], ma20[i]))

        // 涨幅 ≥ 2%
        let prevClose = closes[i - 1]
        let gainPct = prevClose > 0 ? (close - prevClose) / prevClose * 100 : 0
        let strongGain = gainPct >= 2.0

        // 放量：量 > 10 日均量 × 1.5（修正原公式笔误）
        let volMA10 = candles.suffix(10).map(\.volume).reduce(0, +) / 10
        let volSurge = volMA10 > 0 && today.volume > volMA10 * 1.5

        let hit = isSqueezed && crossUp && strongGain && volSurge

        // 强度：粘合越紧、涨幅越大、量能越足越强
        var strength = 0.0
        if hit {
            let squeezeScore = max(0, (0.08 - squeezeRatio) / 0.08) * 40
            let gainScore = min(30, gainPct * 6)
            let volScore = volMA10 > 0 ? min(30, (today.volume / volMA10 - 1.5) * 20) : 0
            strength = min(100, squeezeScore + gainScore + volScore)
        }

        let detail = hit
            ? String(format: "五线粘合 %.1f%% + 一阳穿三线 + 涨 %.1f%% + 量 %.1f倍",
                     squeezeRatio * 100, gainPct, volMA10 > 0 ? today.volume / volMA10 : 0)
            : String(format: "粘合度 %.1f%%%@，穿线%@，涨幅 %.1f%%%@",
                     squeezeRatio * 100, isSqueezed ? "达标" : "不足",
                     crossUp ? "是" : "否", gainPct, volSurge ? "，放量" : "，量不足")

        return Match(id: "squeeze", name: "五线粘合突破", hit: hit,
                     strength: strength, detail: detail, bias: hit ? .buy : .neutral)
    }

    // MARK: - ② 尾盘异动

    /// 乖离强度上穿 + KDJ 拐头 + MACD 底部动能 + 均线多头 + 温和放量。
    /// 温和放量区间 1.2~3 倍，超过 3 倍视为出货。
    static func tailSurge(_ candles: [Candle]) -> Match {
        let n = candles.count
        guard n >= 30 else { return Match(id: "tail", name: "尾盘异动", hit: false, strength: 0, detail: "数据不足", bias: .neutral) }

        let closes = candles.map(\.close)
        let i = n - 1

        // 乖离强度：三价均值相对其 14 日均值的标准化偏离
        let tps = candles.map { ($0.high + $0.low + $0.close) / 3 }
        let tpMA14 = Indicators.sma(tps, period: 14)
        guard tpMA14[i] > 0 else {
            return Match(id: "tail", name: "尾盘异动", hit: false, strength: 0, detail: "数据不足", bias: .neutral)
        }
        let deviation = (tps[i] - tpMA14[i]) / tpMA14[i] * 100

        // KDJ J 值向上
        let kdj = Indicators.kdj(candles)
        let j = kdj.j
        let jUp = i > 0 && j[i] > j[i - 1]

        // MACD 底部动能：柱在扩张（负值收窄或正值放大）
        let macd = Indicators.macd(closes)
        let hist = macd.hist
        let momentumUp = i > 0 && hist[i] > hist[i - 1]

        // 均线多头：MA5 > MA10 > MA20
        let ma5 = Indicators.sma(closes, period: 5)
        let ma10 = Indicators.sma(closes, period: 10)
        let ma20 = Indicators.sma(closes, period: 20)
        let bullAlign = ma5[i] > ma10[i] && ma10[i] > ma20[i]

        // 温和放量 1.2~3 倍
        let volMA5 = candles.suffix(5).map(\.volume).reduce(0, +) / 5
        let volRatio = volMA5 > 0 ? candles[i].volume / volMA5 : 0
        let volOK = volRatio >= 1.2 && volRatio <= 3.0
        let volTooHigh = volRatio > 3.0

        let hit = deviation > 0 && jUp && momentumUp && bullAlign && volOK

        var strength = 0.0
        if hit {
            strength = min(100, 30 + min(30, deviation * 3) + min(40, (volRatio - 1.2) * 30))
        }

        var detail = String(format: "乖离 %+.1f%%，J%@，动能%@，多头%@，量 %.1f倍",
                            deviation, jUp ? "↑" : "↓", momentumUp ? "↑" : "↓",
                            bullAlign ? "✓" : "✗", volRatio)
        if volTooHigh {
            detail += "（量能过大，疑出货）"
        }

        return Match(id: "tail", name: "尾盘异动", hit: hit,
                     strength: strength, detail: detail, bias: hit ? .buy : .neutral)
    }

    // MARK: - ③ 涨停回马枪

    /// 涨停后回调洗盘，缩量止跌 + 动能反转，是二次启动点。
    /// 要点：近期有涨停 → 连续阴跌 → 缩量 → J 值超卖反转。
    static func limitUpPullback(_ candles: [Candle]) -> Match {
        let n = candles.count
        guard n >= 15 else { return Match(id: "pullback", name: "涨停回马枪", hit: false, strength: 0, detail: "数据不足", bias: .neutral) }

        let closes = candles.map(\.close)
        let i = n - 1

        // 近 10 日内是否有涨停（≥9.5%，兼容主板 10%）
        var hasLimitUp = false
        var limitDayIdx = -1
        for k in max(0, n - 12)..<(n - 2) {
            guard k > 0 else { continue }
            let chg = closes[k - 1] > 0 ? (closes[k] - closes[k - 1]) / closes[k - 1] * 100 : 0
            if chg >= 9.5 {
                hasLimitUp = true
                limitDayIdx = k
            }
        }

        // 涨停后连续调整（收盘低于涨停日收盘）
        var pulledBack = false
        if limitDayIdx > 0 {
            let limitClose = closes[limitDayIdx]
            pulledBack = closes[i] < limitClose * 0.98
        }

        // 缩量：今日量 < 5 日均量 × 0.8（抛压衰竭）
        let volMA5 = candles.suffix(5).map(\.volume).reduce(0, +) / 5
        let shrink = volMA5 > 0 && candles[i].volume < volMA5 * 0.8

        // 动能反转：J 值从超卖区拐头
        let kdj = Indicators.kdj(candles)
        let j = kdj.j
        let jReversal = i > 0 && j[i - 1] < 20 && j[i] > j[i - 1]

        // 今日收阳
        let isUp = candles[i].close > candles[i].open

        let hit = hasLimitUp && pulledBack && shrink && jReversal && isUp

        var strength = 0.0
        if hit {
            // J 值越低越超卖，反弹力越强
            let jScore = max(0, (20 - j[i - 1]) / 20) * 50
            let shrinkScore = volMA5 > 0 ? max(0, (1 - candles[i].volume / volMA5)) * 50 : 0
            strength = min(100, jScore + shrinkScore)
        }

        let detail = hit
            ? String(format: "涨停后回调 + 缩量 %.0f%% + J值 %.1f 拐头",
                     volMA5 > 0 ? (1 - candles[i].volume / volMA5) * 100 : 0, j[i])
            : "\(hasLimitUp ? "有涨停" : "无涨停")，\(pulledBack ? "已回调" : "未回调")，\(shrink ? "缩量" : "未缩量")，\(jReversal ? "J拐头" : "J未反转")"

        return Match(id: "pullback", name: "涨停回马枪", hit: hit,
                     strength: strength, detail: detail, bias: hit ? .buy : .neutral)
    }

    // MARK: - ④ 洗盘终结

    /// 急跌制造恐慌 → 缩量企稳 → 放量反攻。
    /// 论坛原文「三日跌>6% + 当日涨>1% + J金叉 + 3日换手>6%」。
    /// 注：社区指出原文涨幅阈值(3%)与代码(1%)不一致，这里统一取 2%。
    static func washoutEnd(_ candles: [Candle]) -> Match {
        let n = candles.count
        guard n >= 25 else { return Match(id: "washout", name: "洗盘终结", hit: false, strength: 0, detail: "数据不足", bias: .neutral) }

        let closes = candles.map(\.close)
        let i = n - 1

        // 三日累计跌幅 > 6%
        let drop3D = i >= 3 && closes[i - 3] > 0
            ? (closes[i] - closes[i - 3]) / closes[i - 3] * 100 : 0

        // 当日涨幅 ≥ 2%（统一阈值）
        let gainToday = i > 0 && closes[i - 1] > 0
            ? (closes[i] - closes[i - 1]) / closes[i - 1] * 100 : 0

        // J 值金叉（J 上穿其 2 日均）
        let kdj = Indicators.kdj(candles)
        let j = kdj.j
        let jCross = i > 1 && j[i - 1] <= (j[i - 1] + j[i - 2]) / 2 && j[i] > j[i - 1]

        // 放量反攻：量 > 5 日均量 × 1.3
        let volMA5 = candles.suffix(5).map(\.volume).reduce(0, +) / 5
        let volSurge = volMA5 > 0 && candles[i].volume > volMA5 * 1.3

        // 今日收阳
        let isUp = candles[i].close > candles[i].open

        // 命中条件：前期有急跌 + 今日放量反攻
        let hadDrop = drop3D < -6.0 || (i >= 5 && closes[i] < closes[i - 5] * 0.94)
        let hit = hadDrop && gainToday >= 2.0 && volSurge && isUp && jCross

        var strength = 0.0
        if hit {
            let dropScore = min(40, abs(drop3D) * 4)
            let gainScore = min(30, gainToday * 8)
            let volScore = volMA5 > 0 ? min(30, (candles[i].volume / volMA5 - 1.3) * 25) : 0
            strength = min(100, dropScore + gainScore + volScore)
        }

        let detail = hit
            ? String(format: "急跌 %.1f%% 后放量反攻 %+.1f%%，J值金叉", drop3D, gainToday)
            : String(format: "3日 %.1f%%，今日 %+.1f%%，%@", drop3D, gainToday, volSurge ? "放量" : "量平")

        return Match(id: "washout", name: "洗盘终结", hit: hit,
                     strength: strength, detail: detail, bias: hit ? .buy : .neutral)
    }

    // MARK: - ⑤ 杯柄突破（欧奈尔体系）

    /// 杯柄形态：长期上涨(A点) → 回调成杯(B点) → 反弹(C点) → 浅回调成柄(D点) → 突破C点。
    /// 要点：柄部位于杯身上半部、缩量、窄幅，突破时放量。
    /// 原公式依赖 RPS（相对强度）外部数据，这里用「个股相对自身均线的强度」替代。
    static func cupHandle(_ candles: [Candle]) -> Match {
        let n = candles.count
        guard n >= 130 else {
            return Match(id: "cup", name: "杯柄突破", hit: false, strength: 0, detail: "数据不足（需130日）", bias: .neutral)
        }

        let closes = candles.map(\.close)
        let highs = candles.map(\.high)
        let lows = candles.map(\.low)
        let i = n - 1

        // 在近 120 日内找 A(最高) → B(最低) → C(反弹高) → D(柄低)
        let lookback = 120
        let start = n - lookback

        // A 点：区间最高价
        var aIdx = start
        for k in start..<n where highs[k] > highs[aIdx] { aIdx = k }
        let aPrice = highs[aIdx]

        // B 点：A 之后的最低价（杯底）
        guard aIdx < n - 5 else {
            return Match(id: "cup", name: "杯柄突破", hit: false, strength: 0, detail: "A点在近期，形态未成形", bias: .neutral)
        }
        var bIdx = aIdx
        for k in aIdx..<n where lows[k] < lows[bIdx] { bIdx = k }
        let bPrice = lows[bIdx]

        // C 点：B 之后的反弹高点（杯沿右侧）
        guard bIdx < n - 3 else {
            return Match(id: "cup", name: "杯柄突破", hit: false, strength: 0, detail: "杯底太近，形态未成形", bias: .neutral)
        }
        var cIdx = bIdx
        for k in bIdx..<n where highs[k] > highs[cIdx] { cIdx = k }
        let cPrice = highs[cIdx]

        // D 点：C 之后的柄部低点
        guard cIdx < n - 1 else {
            return Match(id: "cup", name: "杯柄突破", hit: false, strength: 0, detail: "C点太近", bias: .neutral)
        }
        var dIdx = cIdx
        for k in cIdx..<n where lows[k] < lows[dIdx] { dIdx = k }
        let dPrice = lows[dIdx]

        // ── 条件判定
        // ① 杯深：回调 12%~50%
        let cupDepth = aPrice > 0 ? bPrice / aPrice : 1
        let depthOK = cupDepth > 0.5 && cupDepth < 0.88

        // ② 柄浅：回调 < 15%
        let handleDepth = cPrice > 0 ? dPrice / cPrice : 1
        let handleOK = handleDepth > 0.85

        // ③ 柄部位于杯身上半部
        let midPrice = (aPrice + bPrice) / 2
        let handleHigh = dIdx >= cIdx ? (cIdx..<n).map { lows[$0] }.min() ?? 0 : 0
        let upperHalf = handleHigh > midPrice

        // ④ 周期：A→B 至少 30 日，C→D 至少 4 日
        let abDays = bIdx - aIdx
        let cdDays = n - 1 - cIdx
        let periodOK = abDays >= 30 && cdDays >= 4

        // ⑤ 柄部缩量：柄部期间有量 < 10 日均量
        let volMA10 = Indicators.sma(candles.map(\.volume), period: 10)
        var handleShrink = false
        if cIdx < n {
            for k in cIdx..<n where k < volMA10.count && volMA10[k] > 0 {
                if candles[k].volume < volMA10[k] { handleShrink = true; break }
            }
        }

        // ⑥ 突破：今日收盘突破 C 点，且放量
        let todayClose = closes[i]
        let breakout = todayClose > cPrice
        let volMA10Now = candles.suffix(10).map(\.volume).reduce(0, +) / 10
        let volSurge = volMA10Now > 0 && candles[i].volume > volMA10Now * 1.3

        let hit = depthOK && handleOK && upperHalf && periodOK && handleShrink && breakout && volSurge

        var strength = 0.0
        if hit {
            let depthScore = min(25, (0.88 - cupDepth) * 100)      // 杯越浅越强
            let handleScore = min(25, (handleDepth - 0.85) * 300)  // 柄越浅越好
            let volScore = volMA10Now > 0 ? min(30, (candles[i].volume / volMA10Now - 1.3) * 30) : 0
            let breakScore = cPrice > 0 ? min(20, (todayClose / cPrice - 1) * 400) : 0
            strength = min(100, depthScore + handleScore + volScore + breakScore)
        }

        let detail = hit
            ? String(format: "杯深 %.0f%% + 柄浅 %.0f%% + 突破 C 点 %.1f%% 放量",
                     (1 - cupDepth) * 100, (1 - handleDepth) * 100, (todayClose / cPrice - 1) * 100)
            : "杯深\(depthOK ? "✓" : "✗") 柄浅\(handleOK ? "✓" : "✗") 上半\(upperHalf ? "✓" : "✗") 突破\(breakout ? "✓" : "✗")"

        return Match(id: "cup", name: "杯柄突破", hit: hit,
                     strength: strength, detail: detail, bias: hit ? .buy : .neutral)
    }

    // MARK: - ⑥ MACD 背离

    /// 价格创新高但 MACD 柱峰值走低 = 顶背离（卖）；
    /// 价格创新低但 MACD 柱峰值抬高 = 底背离（买）。
    static func macdDivergence(_ candles: [Candle]) -> Match {
        let n = candles.count
        guard n >= 40 else { return Match(id: "diverge", name: "MACD背离", hit: false, strength: 0, detail: "数据不足", bias: .neutral) }

        let closes = candles.map(\.close)
        let macd = Indicators.macd(closes)
        let hist = macd.hist

        // 找最近两个波段的高低点（简化为窗口极值）
        let window = 20
        let recentStart = n - window
        guard recentStart > window else {
            return Match(id: "diverge", name: "MACD背离", hit: false, strength: 0, detail: "数据不足", bias: .neutral)
        }

        // 前段窗口 vs 后段窗口
        let prevRange = (n - 2 * window)..<(n - window)
        let currRange = recentStart..<n

        let prevHigh = prevRange.map { closes[$0] }.max() ?? 0
        let currHigh = currRange.map { closes[$0] }.max() ?? 0
        let prevLow = prevRange.map { closes[$0] }.min() ?? .greatestFiniteMagnitude
        let currLow = currRange.map { closes[$0] }.min() ?? 0

        let prevHistMax = prevRange.map { hist[$0] }.max() ?? 0
        let currHistMax = currRange.map { hist[$0] }.max() ?? 0
        let prevHistMin = prevRange.map { hist[$0] }.min() ?? 0
        let currHistMin = currRange.map { hist[$0] }.min() ?? 0

        // 顶背离：价新高，动能未新高
        let topDiverge = currHigh > prevHigh * 1.01 && currHistMax < prevHistMax * 0.9
        // 底背离：价新低，动能未新低
        let bottomDiverge = currLow < prevLow * 0.99 && currHistMin > prevHistMin * 0.9

        let hit = topDiverge || bottomDiverge

        var strength = 0.0
        var bias: Match.Bias = .neutral
        var detail = "无背离"

        if bottomDiverge {
            bias = .buy
            let priceDrop = prevLow > 0 ? (prevLow - currLow) / prevLow * 100 : 0
            let momentumGain = prevHistMin != 0 ? (currHistMin - prevHistMin) / abs(prevHistMin) * 100 : 0
            strength = min(100, 50 + priceDrop * 5 + max(0, momentumGain) * 0.3)
            detail = String(format: "底背离：价创新低 %.1f%% 但动能抬高 %.0f%%", priceDrop, momentumGain)
        } else if topDiverge {
            bias = .sell
            let priceRise = prevHigh > 0 ? (currHigh - prevHigh) / prevHigh * 100 : 0
            let momDecay = prevHistMax != 0 ? (currHistMax - prevHistMax) / abs(prevHistMax) * 100 : 0
            strength = min(100, 50 + priceRise * 5 + abs(min(0, momDecay)) * 0.3)
            detail = String(format: "顶背离：价创新高 %.1f%% 但动能衰减 %.0f%%", priceRise, momDecay)
        }

        return Match(id: "diverge", name: "MACD背离", hit: hit,
                     strength: strength, detail: detail, bias: bias)
    }
}
