import Foundation

/// 支撑/压力位识别器。
///
/// 采用四种互相独立的证据源，最后按价格邻近度聚类合并，得到带强度评分的价位：
/// 1. 摆动点（Swing Pivot）——局部极值被多次触碰
/// 2. 成交密集区（Volume Profile）——筹码堆积，天然的买卖壁垒
/// 3. 均线系统 —— 20/60/120 日均线的动态支撑压力
/// 4. 斐波那契回撤 —— 主趋势区间的黄金分割
/// 5. 前高前低 —— 历史关键价位
enum LevelEngine {

    struct Config {
        var swingLookback: Int = 5
        var clusterTolerance: Double = 0.022    // 2.2% 内视为同一价位
        var maxLevels: Int = 6
        var volumeBins: Int = 60
        /// 只保留距现价该百分比以内的价位
        var maxDistancePct: Double = 16.0
    }

    /// 计算支撑压力位（不含现价距离，由调用方填充）
    static func detect(candles: [Candle], config: Config = Config()) -> [PriceLevel] {
        guard candles.count >= 20 else { return [] }
        let current = candles.last!.close
        var raw: [(price: Double, source: LevelSource, touches: Int, bonus: Double)] = []

        // 1. 摆动点
        let swing = config.swingLookback
        if candles.count > swing * 2 {
            for i in swing..<(candles.count - swing) {
                let c = candles[i]
                var isHigh = true
                var isLow = true
                for j in (i - swing)...(i + swing) where j != i {
                    if candles[j].high >= c.high { isHigh = false }
                    if candles[j].low <= c.low { isLow = false }
                }
                if isHigh { raw.append((c.high, .swing, 1, 0)) }
                if isLow { raw.append((c.low, .swing, 1, 0)) }
            }
            // 全局最高最低
            if let hi = candles.map(\.high).max() {
                raw.append((hi, .previousExtreme, 2, 6))
            }
            if let lo = candles.map(\.low).min() {
                raw.append((lo, .previousExtreme, 2, 6))
            }
        }

        // 2. 成交密集区：把价格区间分箱，累加成交量
        let profile = volumeProfile(candles: candles, bins: config.volumeBins)
        for node in profile.highVolumeNodes(limit: 4) {
            raw.append((node.price, .volumeProfile, node.touches, node.strength))
        }

        // 3. 均线
        let closes = candles.map(\.close)
        for period in [20, 60, 120] where candles.count >= period {
            if let v = Indicators.sma(closes, period: period).lastFinite {
                raw.append((v, .movingAverage, 1, period >= 60 ? 5 : 2))
            }
        }

        // 4. 斐波那契回撤（取最近 N 根的主区间）
        let lookback = min(candles.count, 120)
        let window = Array(candles.suffix(lookback))
        if let hi = window.map(\.high).max(), let lo = window.map(\.low).min(), hi > lo {
            let range = hi - lo
            for ratio in [0.236, 0.382, 0.5, 0.618, 0.786] {
                raw.append((hi - range * ratio, .fibonacci, 1, 0))
            }
            raw.append((hi, .previousExtreme, 1, 2))
            raw.append((lo, .previousExtreme, 1, 2))
        }

        guard !raw.isEmpty else { return [] }

        // 5. 聚类合并
        var clusters: [Cluster] = []
        for item in raw.sorted(by: { $0.price < $1.price }) {
            if let idx = clusters.firstIndex(where: { abs($0.center - item.price) / max(item.price, 0.0001) <= config.clusterTolerance }) {
                clusters[idx].absorb(price: item.price, source: item.source, touches: item.touches, bonus: item.bonus)
            } else {
                clusters.append(Cluster(price: item.price, source: item.source, touches: item.touches, bonus: item.bonus))
            }
        }

        // 5b. 二次合并：聚类中心可能因吸收顺序不同而落得很近
        var mergedClusters: [Cluster] = []
        for c in clusters.sorted(by: { $0.center < $1.center }) {
            if let idx = mergedClusters.firstIndex(where: {
                abs($0.center - c.center) / max(c.center, 0.0001) <= config.clusterTolerance * 0.9
            }) {
                mergedClusters[idx].merge(c)
            } else {
                mergedClusters.append(c)
            }
        }
        clusters = mergedClusters

        // 6. 打分
        //
        // 分数的含义是「这个价位被多少条互相独立的证据支持」。
        // 单一来源的价位应当明显弱于三四个来源重合的价位，
        // 因此以「来源广度」为主项、「触碰次数」和「筹码量」为辅项。
        var levels: [PriceLevel] = []
        for c in clusters {
            let distancePct = (c.center - current) / current * 100
            let distinct = Double(c.sourceCounts.count)

            // 来源广度：1 个来源 ≈ 22 分，每多一种 +17 分（边际递减）
            var score = 22.0 + (distinct - 1) * 17.0
            if distinct >= 4 { score += 6 }        // 四种以上共振

            // 同来源的多次触发（例如多根均线汇聚）
            let totalHits = c.sourceCounts.values.reduce(0, +)
            score += Double(min(totalHits - c.sourceCounts.count, 6)) * 3.0

            // 触碰次数：反复验证过的价位更可靠
            score += Double(min(c.touches, 8)) * 2.6

            // 成交密集区是筹码壁垒，加权最高
            if let vpCount = c.sourceCounts[.volumeProfile] {
                score += min(Double(vpCount) * 5.0, 14)
            }
            // 均线越多越强
            if let maCount = c.sourceCounts[.movingAverage] {
                score += min(Double(maCount) * 2.5, 7)
            }

            score += min(c.bonus, 12)
            score = min(score, 100)

            levels.append(PriceLevel(
                price: c.center,
                kind: c.center >= current ? .resistance : .support,
                score: score,
                sources: Set(c.sourceCounts.keys),
                touches: c.touches,
                distancePct: distancePct
            ))
        }

        // 7. 距离带过滤
        //
        // 超出 ±maxDistancePct 的价位对实际交易没有指导意义
        //（例如现价上方 30% 的"压力"），先剔除再排序。
        let maxDistance = config.maxDistancePct
        levels = levels.filter { abs($0.distancePct) <= maxDistance }

        let supports = levels.filter { $0.kind == .support }
            .sorted { $0.price > $1.price }        // 由近及远
        let resistances = levels.filter { $0.kind == .resistance }
            .sorted { $0.price < $1.price }        // 由近及远

        var picked = Array(supports.prefix(config.maxLevels / 2)) + Array(resistances.prefix(config.maxLevels / 2))

        // 若某一侧为空，用另一侧补齐
        if picked.count < config.maxLevels {
            let extra = levels.sorted { $0.score > $1.score }.filter { l in !picked.contains(where: { $0.id == l.id }) }
            picked.append(contentsOf: extra.prefix(config.maxLevels - picked.count))
        }
        return picked.sorted { $0.price > $1.price }
    }

    // MARK: - 成交密集区

    struct VolumeNode {
        var price: Double
        var volume: Double
        var touches: Int
        var strength: Double   // 0~15
    }

    struct VolumeProfile {
        var nodes: [VolumeNode]
        var pointOfControl: Double?

        func highVolumeNodes(limit: Int) -> [VolumeNode] {
            // 只取显著高于均值的节点，避免满屏噪音
            guard !nodes.isEmpty else { return [] }
            let avg = nodes.map(\.volume).reduce(0, +) / Double(nodes.count)
            let thresh = avg * 1.25
            return nodes.filter { $0.volume >= thresh }
                .sorted { $0.volume > $1.volume }
                .prefix(limit)
                .map { $0 }
        }
    }

    static func volumeProfile(candles: [Candle], bins: Int = 60) -> VolumeProfile {
        let recent = Array(candles.suffix(180))
        guard let hi = recent.map(\.high).max(), let lo = recent.map(\.low).min(), hi > lo, bins > 1 else {
            return VolumeProfile(nodes: [], pointOfControl: nil)
        }
        let step = (hi - lo) / Double(bins)
        var volumes = Array(repeating: 0.0, count: bins)
        var touches = Array(repeating: 0, count: bins)

        for c in recent {
            // 单根K线的成交量按其价格区间均摊到覆盖的箱体
            let loIdx = max(0, min(bins - 1, Int((c.low - lo) / step)))
            let hiIdx = max(0, min(bins - 1, Int((c.high - lo) / step)))
            let span = hiIdx - loIdx + 1
            let share = c.volume / Double(span)
            for b in loIdx...hiIdx { volumes[b] += share }
            touches[min(bins - 1, max(0, Int((c.close - lo) / step)))] += 1
        }

        let maxVol = volumes.max() ?? 1
        var nodes: [VolumeNode] = []
        for b in 0..<bins where volumes[b] > 0 {
            let price = lo + step * (Double(b) + 0.5)
            let rel = maxVol > 0 ? volumes[b] / maxVol : 0
            nodes.append(VolumeNode(
                price: price,
                volume: volumes[b],
                touches: touches[b],
                strength: rel * 15
            ))
        }
        let pocIndex = volumes.enumerated().max { $0.element < $1.element }?.offset
        return VolumeProfile(nodes: nodes, pointOfControl: pocIndex.map { lo + step * (Double($0) + 0.5) })
    }

    // MARK: - 聚类容器

    private struct Cluster {
        var sumPrice: Double
        var weight: Double
        var touches: Int
        var bonus: Double
        var sourceCounts: [LevelSource: Int] = [:]

        init(price: Double, source: LevelSource, touches: Int, bonus: Double) {
            self.sumPrice = price
            self.weight = source.weight
            self.touches = touches
            self.bonus = bonus
            self.sourceCounts = [source: 1]
        }

        var center: Double { weight > 0 ? sumPrice / weight : 0 }

        mutating func merge(_ other: Cluster) {
            sumPrice += other.sumPrice
            weight += other.weight
            touches += other.touches
            bonus += other.bonus
            for (src, count) in other.sourceCounts {
                sourceCounts[src, default: 0] += count
            }
        }

        mutating func absorb(price: Double, source: LevelSource, touches: Int, bonus: Double) {
            let w = source.weight
            sumPrice += price * w
            weight += w
            self.touches += touches
            self.bonus += bonus * 0.5
            sourceCounts[source, default: 0] += 1
        }
    }
}

// MARK: - 趋势结构

struct TrendStructure {
    var direction: TrendDirection
    var strength: Double        // 0~100
    var ma20Slope: Double
    var ma60Slope: Double
    var priceVsMA20: Double     // %
    var priceVsMA60: Double
    var higherHighs: Bool
    var higherLows: Bool
    var lowerHighs: Bool
    var lowerLows: Bool
    var description: String
}

enum TrendDirection: String {
    case strongUp, up, sideways, down, strongDown

    var label: String {
        switch self {
        case .strongUp: return "强势上涨"
        case .up: return "震荡上行"
        case .sideways: return "区间震荡"
        case .down: return "震荡下行"
        case .strongDown: return "弱势下跌"
        }
    }

    var isBullish: Bool { self == .strongUp || self == .up }
}

enum TrendEngine {
    static func analyze(candles: [Candle]) -> TrendStructure? {
        guard candles.count >= 60 else { return nil }
        let closes = candles.map(\.close)
        let n = closes.count - 1
        let last = closes[n]

        let ma20 = Indicators.sma(closes, period: 20)
        let ma60 = Indicators.sma(closes, period: 60)
        guard let m20 = ma20.lastFinite, let m60 = ma60.lastFinite else { return nil }

        let slope20 = Indicators.slopePercent(closes, index: n, period: 20)
        let slope60 = Indicators.slopePercent(closes, index: n, period: 60)

        // 摆动结构：最近 60 根内的峰谷序列
        let swing = 5
        var highs: [Double] = []
        var lows: [Double] = []
        let start = max(swing, candles.count - 60)
        if start < candles.count - swing {
            for i in start..<(candles.count - swing) {
                let c = candles[i]
                var isH = true, isL = true
                for j in (i - swing)...(i + swing) where j != i {
                    if candles[j].high >= c.high { isH = false }
                    if candles[j].low <= c.low { isL = false }
                }
                if isH { highs.append(c.high) }
                if isL { lows.append(c.low) }
            }
        }
        let hh = highs.count >= 2 && highs.suffix(2).first! < highs.last!
        let hl = lows.count >= 2 && lows.suffix(2).first! < lows.last!
        let lh = highs.count >= 2 && highs.suffix(2).first! > highs.last!
        let ll = lows.count >= 2 && lows.suffix(2).first! > lows.last!

        // 综合打分
        var score = 50.0
        score += max(-18, min(18, slope20 * 6))
        score += max(-14, min(14, slope60 * 4))
        if last > m20 { score += 6 } else { score -= 6 }
        if last > m60 { score += 6 } else { score -= 6 }
        if m20 > m60 { score += 7 } else { score -= 7 }
        if hh && hl { score += 8 }
        if lh && ll { score -= 8 }
        score = max(0, min(100, score))

        let dir: TrendDirection
        switch score {
        case 78...: dir = .strongUp
        case 60..<78: dir = .up
        case 42..<60: dir = .sideways
        case 25..<42: dir = .down
        default: dir = .strongDown
        }

        var parts: [String] = []
        if hh && hl { parts.append("高点抬高、低点抬高") }
        else if lh && ll { parts.append("高点降低、低点降低") }
        if slope20 > 0.15 { parts.append("短均线陡峭上行") }
        else if slope20 < -0.15 { parts.append("短均线陡峭下行") }
        if abs(last / m20 - 1) > 0.06 { parts.append(last > m20 ? "价格远离20均线上方" : "价格远离20均线下方") }
        if parts.isEmpty { parts.append("均线缠绕，暂无方向") }

        return TrendStructure(
            direction: dir,
            strength: score,
            ma20Slope: slope20,
            ma60Slope: slope60,
            priceVsMA20: (last / m20 - 1) * 100,
            priceVsMA60: (last / m60 - 1) * 100,
            higherHighs: hh,
            higherLows: hl,
            lowerHighs: lh,
            lowerLows: ll,
            description: parts.joined(separator: "；")
        )
    }
}
