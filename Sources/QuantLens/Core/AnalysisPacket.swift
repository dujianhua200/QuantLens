import Foundation

// MARK: - 分析包（复制给 Kit 用）

/// 把当前标的已算好的全部信号整理成一段自包含中文文本，供用户复制后粘贴到
/// 与 Kit 的聊天里分析。纯函数：不联网、不自动发送（不存在直连 Kit 的通道，
/// 绝不假装有）、不编造任何数字——每个数字都来自输入。
enum AnalysisPacket {

    struct Input {
        var security: Security
        var quote: Quote?
        /// 无行情快照时的现价兜底：最新一根 K 线收盘价（会在文本中明确标注）。
        var lastClose: Double?
        var generatedAt: Date
        var summary: String
        var emotion: EmotionSnapshot?
        var tradePoints: [TradePointSignal]
        var fearSignals: [FearSignal]
        var supports: [PriceLevel]
        var resistances: [PriceLevel]
        var intraday: [BuyPointEntry]
    }

    /// 日线买卖点最多列 10 条（最近的优先）；支撑/压力各最多 3 条（最近的优先）。
    static let maxTradePoints = 10
    static let maxLevels = 3

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    static func build(_ input: Input) -> String {
        var lines: [String] = []
        let stamp = dateTimeFormatter.string(from: input.generatedAt)
        lines.append("[QuantLens 分析包] \(input.security.name)（\(input.security.id)） 生成时间：\(stamp)")
        lines.append("")
        appendQuote(&lines, quote: input.quote, lastClose: input.lastClose)
        lines.append("")
        appendTrendAndEmotion(&lines, summary: input.summary, emotion: input.emotion)
        lines.append("")
        appendTradePoints(&lines, points: input.tradePoints)
        lines.append("")
        appendFearSignals(&lines, signals: input.fearSignals)
        lines.append("")
        appendLevels(&lines, supports: input.supports, resistances: input.resistances)
        lines.append("")
        appendIntraday(&lines, entries: input.intraday)
        lines.append("")
        lines.append("[待填] 持有成本：____（请填写）")
        lines.append("[待填] 仓位占比：____%（请填写）")
        lines.append("")
        lines.append("以上数字全部来自 QuantLens 规则引擎计算，未经人工核对；仅供娱乐讨论，不构成投资建议。")
        lines.append("请结合以上信息，讨论这只标的的短线状态与风险点。")
        return lines.joined(separator: "\n")
    }

    private static func appendQuote(_ lines: inout [String], quote: Quote?, lastClose: Double?) {
        lines.append("[行情]")
        guard let q = quote else {
            if let c = lastClose {
                lines.append("最新收盘 \(Fmt.price(c))（无实时行情快照，以 K 线最后一根收盘价为准）。")
            } else {
                lines.append("暂无行情快照。")
            }
            return
        }
        let changeText = Fmt.pct(q.changePct)
        lines.append("现价 \(Fmt.price(q.price))（\(changeText)），开 \(Fmt.price(q.open))，高 \(Fmt.price(q.high))，低 \(Fmt.price(q.low))，换手 \(Fmt.pct(q.turnoverRate, sign: false))，成交额 \(Fmt.money(q.amount))。")
    }

    private static func appendTrendAndEmotion(_ lines: inout [String], summary: String,
                                              emotion: EmotionSnapshot?) {
        lines.append("[趋势与情绪]")
        if summary.isEmpty {
            lines.append("暂无趋势结论。")
        } else {
            lines.append(summary)
        }
        guard let e = emotion else {
            lines.append("暂无市场情绪快照。")
            return
        }
        let scoreText = String(format: "%.0f", e.score)
        let fearText = String(format: "%.0f", e.fear)
        let greedText = String(format: "%.0f", e.greed)
        let ratioText = String(format: "%.0f", e.breadth.advanceRatio * 100)
        lines.append("市场情绪：\(e.phase.rawValue)（\(scoreText) 分，恐惧 \(fearText) / 贪婪 \(greedText)），上涨占比 \(ratioText)%（样本 \(e.breadth.total) 只，\(e.breadth.sourceLabel)）。")
        if !e.headline.isEmpty {
            lines.append(e.headline)
        }
    }

    private static func appendTradePoints(_ lines: inout [String], points: [TradePointSignal]) {
        lines.append("[日线买卖点]")
        if points.isEmpty {
            lines.append("无。")
            return
        }
        var sorted = points
        sorted.sort { $0.date > $1.date }
        let top = Array(sorted.prefix(maxTradePoints))
        for p in top {
            let rText = String(format: "%.1f", p.rMultiple)
            let strengthText = String(format: "%.0f", p.strength)
            var line = "\(Fmt.date(p.date)) \(p.direction.shortLabel) \(p.kind.code) \(p.kind.label) @\(Fmt.price(p.price))，止损 \(Fmt.price(p.stopLoss))，目标 \(Fmt.price(p.target))，\(rText)R，强度 \(strengthText)"
            if p.isStrong { line += "（强）" }
            if p.isVetoed { line += "（环境否决）" }
            if !p.sizeNote.isEmpty { line += "，\(p.sizeNote)" }
            line += "——\(p.reason)"
            lines.append(line)
        }
    }

    private static func appendFearSignals(_ lines: inout [String], signals: [FearSignal]) {
        lines.append("[恐惧 / 贪婪信号]")
        if signals.isEmpty {
            lines.append("无。")
            return
        }
        var sorted = signals
        sorted.sort { $0.date > $1.date }
        for fs in sorted {
            let scoreText = String(format: "%.0f", fs.score)
            let line = "\(Fmt.date(fs.date)) \(fs.kind.label)（\(fs.sentiment.rawValue)，\(scoreText) 分）@\(Fmt.price(fs.price))——\(fs.reason)"
            lines.append(line)
        }
    }

    private static func appendLevels(_ lines: inout [String], supports: [PriceLevel],
                                     resistances: [PriceLevel]) {
        lines.append("[支撑 / 压力]")
        var sortedSupports = supports
        sortedSupports.sort { $0.price > $1.price }
        let nearSupports = Array(sortedSupports.prefix(maxLevels))
        if nearSupports.isEmpty {
            lines.append("支撑：无。")
        } else {
            for lv in nearSupports {
                let distText = Fmt.pct(lv.distancePct, sign: false)
                lines.append("支撑 \(Fmt.price(lv.price))（\(lv.strengthLabel)，距现价 \(distText)，触碰 \(lv.touches) 次）。")
            }
        }
        var sortedResistances = resistances
        sortedResistances.sort { $0.price < $1.price }
        let nearResistances = Array(sortedResistances.prefix(maxLevels))
        if nearResistances.isEmpty {
            lines.append("压力：无。")
        } else {
            for lv in nearResistances {
                let distText = Fmt.pct(lv.distancePct, sign: false)
                lines.append("压力 \(Fmt.price(lv.price))（\(lv.strengthLabel)，距现价 \(distText)，触碰 \(lv.touches) 次）。")
            }
        }
    }

    private static func appendIntraday(_ lines: inout [String], entries: [BuyPointEntry]) {
        lines.append("[分时信号]")
        if entries.isEmpty {
            lines.append("无。")
            return
        }
        var sorted = entries
        sorted.sort { $0.trigger.time > $1.trigger.time }
        for e in sorted {
            let t = e.trigger
            let strengthText = String(format: "%.0f", t.strength)
            let line = "\(Fmt.date(t.time, intraday: true)) \(t.direction.shortLabel) \(t.kind.label) @\(Fmt.price(t.price))，强度 \(strengthText)——\(t.reason)"
            lines.append(line)
        }
    }
}
