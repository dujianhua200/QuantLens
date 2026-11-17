import Foundation

// MARK: - 市场宽度快照

/// 横截面宽度数据：情绪引擎的唯一输入。
///
/// 字段全部来自已有行情口径，不新增接口：
/// - 竞价池排行（新浪 Market_Center，约 400 只）：涨跌幅 / 高低价
/// - 自选快照（腾讯 qt，兜底）：现价 / 昨收 / 高低价
/// 字段缺失时对应分量自动降级（见 `hasHighData`），不编造数据。
struct MarketBreadth: Hashable {
    var total: Int = 0
    var advancing: Int = 0
    var declining: Int = 0
    var flat: Int = 0
    var limitUp: Int = 0
    var limitDown: Int = 0
    /// 曾触涨停但未封住（炸板）。high 字段缺失时为 0，需结合 `hasHighData` 解读
    var limitUpBroken: Int = 0
    /// 涨幅 > 3% 的家数
    var strongUp: Int = 0
    /// 跌幅 < -3% 的家数
    var strongDown: Int = 0
    /// 涨跌幅之和（算均值用）
    var changeSum: Double = 0
    /// 带有效高价数据的样本数（用于判断炸板率是否可信）
    var highKnownCount: Int = 0
    /// 样本来源说明，如“竞价池 382 只”“自选 A 股 10 只”
    var sourceLabel: String = ""

    var advanceRatio: Double {
        guard total > 0 else { return 0.5 }
        return Double(advancing) / Double(total)
    }

    var avgChangePct: Double {
        guard total > 0 else { return 0 }
        return changeSum / Double(total)
    }

    var limitUpRatio: Double {
        guard total > 0 else { return 0 }
        return Double(limitUp) / Double(total)
    }

    var limitDownRatio: Double {
        guard total > 0 else { return 0 }
        return Double(limitDown) / Double(total)
    }

    var strongUpRatio: Double {
        guard total > 0 else { return 0 }
        return Double(strongUp) / Double(total)
    }

    var strongDownRatio: Double {
        guard total > 0 else { return 0 }
        return Double(strongDown) / Double(total)
    }

    /// 炸板率 = 炸板 / (涨停 + 炸板)。无高价数据时返回 0，调用方看 `hasHighData`。
    var breakRatio: Double {
        let denom = limitUp + limitUpBroken
        guard denom > 0 else { return 0 }
        return Double(limitUpBroken) / Double(denom)
    }

    var hasHighData: Bool { highKnownCount > 0 }
}

// MARK: - 情绪周期相位

/// 情绪周期五相位。判定只用当期宽度快照（无历史序列时不推断趋势），
/// “退潮”需要亢奋中的炸板/分化证据，不只看分数高低。
enum EmotionPhase: String, Hashable {
    case ice = "冰点"
    case recovery = "回暖"
    case chaos = "混沌"
    case euphoria = "亢奋"
    case ebb = "退潮"

    /// 一句话相位解读（描述市场状态，不构成操作建议）
    var hint: String {
        switch self {
        case .ice: return "恐慌弥漫，杀跌动能集中宣泄，等待恐惧衰竭的信号"
        case .recovery: return "恐慌缓解，承接开始出现，关注企稳类信号是否确认"
        case .chaos: return "多空拉锯，没有一致方向，信号成功率参考意义下降"
        case .euphoria: return "贪婪主导，追高资金踊跃，警惕情绪过热后的波动"
        case .ebb: return "亢奋中出现炸板与分化，获利兑现压力上升"
        }
    }

    /// 仓位参考（仅供参考的观察口径，不是仓位建议）
    var positionHint: String {
        switch self {
        case .ice: return "仓位参考：偏低观察"
        case .recovery: return "仓位参考：轻仓试探观察"
        case .chaos: return "仓位参考：中性观察"
        case .euphoria: return "仓位参考：偏高但警惕过热"
        case .ebb: return "仓位参考：偏低观察，警惕兑现"
        }
    }
}

// MARK: - 情绪快照

struct EmotionSnapshot: Hashable {
    /// 情绪总分 0~100，50 为中性
    var score: Double
    /// 恐惧分量 0~100（跌停、弱势股、平均跌幅的合成）
    var fear: Double
    /// 贪婪分量 0~100（涨停、强势股、平均涨幅的合成）
    var greed: Double
    var phase: EmotionPhase
    /// 一句话解读（含关键宽度数字）
    var headline: String
    var breadth: MarketBreadth
    var updatedAt: Date
}

// MARK: - 情绪引擎

/// 把“人性的贪婪与恐惧”量化成可比较的分数与相位。
///
/// 口径（全部来自宽度快照，无主观参数）：
/// - 贪婪分量 = 涨停占比×300 + 强势股占比×120 + 正平均涨幅×8 + 上涨占比×20，上限 100
/// - 恐惧分量 = 跌停占比×300 + 弱势股占比×120 + 负平均涨幅×8 + 下跌占比×20，上限 100
/// - 情绪分 = 50 + (贪婪 - 恐惧) × 0.5，钳制 0~100
/// - 相位：<20 冰点 / <40 回暖 / <60 混沌 / ≥60 且炸板率>35% 或跌停占比>2% 时退潮 / 其余亢奋
///
/// 连板高度无法从现有字段得到（需全市场逐只 K 线历史），本引擎不编造，
/// 以“涨停家数 + 强势股占比”作为连板动量的代理，并在 README 中如实说明。
enum EmotionEngine {

    static func snapshot(breadth: MarketBreadth, at date: Date = Date()) -> EmotionSnapshot {
        guard breadth.total > 0 else {
            return EmotionSnapshot(
                score: 50, fear: 0, greed: 0, phase: .chaos,
                headline: "暂无宽度数据，情绪无法评估",
                breadth: breadth, updatedAt: date
            )
        }

        let adv = breadth.advanceRatio
        let avg = breadth.avgChangePct

        var greed = breadth.limitUpRatio * 300
        greed += breadth.strongUpRatio * 120
        greed += max(0, avg) * 8
        greed += adv * 20
        greed = min(100, greed)

        var fear = breadth.limitDownRatio * 300
        fear += breadth.strongDownRatio * 120
        fear += max(0, -avg) * 8
        fear += (1 - adv) * 20
        fear = min(100, fear)

        var score = 50 + (greed - fear) * 0.5
        score = max(0, min(100, score))

        let phase = phaseFor(score: score, breadth: breadth)
        let headline = headlineFor(score: score, phase: phase, breadth: breadth)

        return EmotionSnapshot(
            score: score, fear: fear, greed: greed, phase: phase,
            headline: headline, breadth: breadth, updatedAt: date
        )
    }

    private static func phaseFor(score: Double, breadth: MarketBreadth) -> EmotionPhase {
        if score < 20 { return .ice }
        if score < 40 { return .recovery }
        if score < 60 { return .chaos }
        // 高分段出现炸板或跌停分化 = 亢奋中的退潮迹象
        let ebbByBreak = breadth.hasHighData && breadth.breakRatio > 0.35
            && (breadth.limitUp + breadth.limitUpBroken) >= 5
        let ebbByDivergence = breadth.limitDownRatio > 0.02
        if ebbByBreak || ebbByDivergence { return .ebb }
        return .euphoria
    }

    private static func headlineFor(score: Double, phase: EmotionPhase, breadth: MarketBreadth) -> String {
        var parts: [String] = []
        let advPct = breadth.advanceRatio * 100
        parts.append("上涨 \(Fmt.price(advPct, decimals: 0))%")
        parts.append("涨停 \(breadth.limitUp) 家")
        parts.append("跌停 \(breadth.limitDown) 家")
        if breadth.hasHighData, breadth.limitUp + breadth.limitUpBroken > 0 {
            let br = breadth.breakRatio * 100
            parts.append("炸板率 \(Fmt.price(br, decimals: 0))%")
        }
        parts.append("均涨 \(Fmt.pct(breadth.avgChangePct, decimals: 1))")
        let joined = parts.joined(separator: " · ")
        return "\(phase.rawValue) \(Fmt.price(score, decimals: 0)) 分：\(joined)"
    }

    // MARK: - 宽度构建

    /// 从自选快照构建宽度（兜底口径，样本小，标签如实注明）。
    /// 只统计 A 股（沪/深/北交所），港美股与指数不进入情绪统计。
    static func breadth(from quotes: [Quote]) -> MarketBreadth {
        var b = MarketBreadth()
        var count = 0
        for q in quotes {
            let m = q.security.market
            guard m == .sh || m == .sz || m == .bj else { continue }
            guard q.prevClose > 0 else { continue }
            count += 1
            let chg = q.changePct
            b.changeSum += chg
            if chg > 0.05 {
                b.advancing += 1
            } else if chg < -0.05 {
                b.declining += 1
            } else {
                b.flat += 1
            }
            if chg > 3 { b.strongUp += 1 }
            if chg < -3 { b.strongDown += 1 }
            let limit = limitPct(for: q.security.symbol, market: m)
            let upPrice = q.prevClose * (1 + limit)
            let downPrice = q.prevClose * (1 - limit)
            if q.price >= upPrice * 0.998 { b.limitUp += 1 }
            if q.price <= downPrice * 1.002 { b.limitDown += 1 }
            if q.high > 0 {
                b.highKnownCount += 1
                let touchedUp = q.high >= upPrice * 0.998
                let closedBelow = q.price < q.high * 0.997
                if touchedUp && closedBelow { b.limitUpBroken += 1 }
            }
        }
        b.total = count
        b.sourceLabel = "自选 A 股 \(count) 只"
        return b
    }

    /// 从竞价池排行行构建宽度（主口径，样本约数百只）。
    /// 每行字段缺失时按 0 处理并计入“未知”，不影响其它分量。
    static func breadth(rows: [PoolRow]) -> MarketBreadth {
        var b = MarketBreadth()
        var count = 0
        for row in rows {
            guard row.settlement > 0 else { continue }
            count += 1
            var chg = row.changePct
            if chg == nil {
                if row.trade > 0 {
                    chg = (row.trade - row.settlement) / row.settlement * 100
                } else {
                    chg = 0
                }
            }
            let c = chg ?? 0
            b.changeSum += c
            if c > 0.05 {
                b.advancing += 1
            } else if c < -0.05 {
                b.declining += 1
            } else {
                b.flat += 1
            }
            if c > 3 { b.strongUp += 1 }
            if c < -3 { b.strongDown += 1 }
            let limit = limitPct(for: row.code, market: row.market)
            let upPrice = row.settlement * (1 + limit)
            let downPrice = row.settlement * (1 - limit)
            let price = row.trade > 0 ? row.trade : row.settlement
            if price >= upPrice * 0.998 { b.limitUp += 1 }
            if price <= downPrice * 1.002 { b.limitDown += 1 }
            if row.high > 0 {
                b.highKnownCount += 1
                let touchedUp = row.high >= upPrice * 0.998
                let closedBelow = price < row.high * 0.997
                if touchedUp && closedBelow { b.limitUpBroken += 1 }
            }
        }
        b.total = count
        b.sourceLabel = "竞价池 \(count) 只"
        return b
    }

    /// 排行行（竞价池原始字段的最小投影，供宽度统计用）
    struct PoolRow: Hashable {
        var code: String
        var market: Market
        var changePct: Double?
        var trade: Double
        var settlement: Double
        var high: Double
        var low: Double
    }

    /// 涨跌停幅度（小数）。按代码前缀区分：
    /// 创业板 30 / 科创板 68 → 20%；北交所 8/4/92 → 30%；其余主板 → 10%。
    /// ST 股在候选池构建时已排除，这里不处理 5% 情形。
    static func limitPct(for code: String, market: Market) -> Double {
        if market == .bj { return 0.30 }
        if code.hasPrefix("30") || code.hasPrefix("68") { return 0.20 }
        if code.hasPrefix("8") || code.hasPrefix("4") || code.hasPrefix("92") { return 0.30 }
        return 0.10
    }
}
