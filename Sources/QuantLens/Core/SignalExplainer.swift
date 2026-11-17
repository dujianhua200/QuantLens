import Foundation

// MARK: - 模板解释器（确定性基线，永远可用）

/// "微型思维辅助模型"的基线：按买卖点字段确定性生成中文推理文字，不依赖任何模型、
/// 不联网、永不编造数字。本地 LLM 只是同一份数字的另一种说法，模型不可用或
/// 输出校验失败时一律回落到本模板。
enum SignalExplainer {

    /// 单点解释：形态 + 触发价 + 止损/目标/R 值 + 失效条件。只引用给定数字。
    static func explain(_ p: TradePointSignal) -> String {
        var parts: [String] = []
        parts.append("\(p.reason)。")
        let rText = String(format: "%.1f", p.rMultiple)
        if p.direction == .buy {
            parts.append("触发价 \(Fmt.price(p.price))，止损 \(Fmt.price(p.stopLoss))，目标 \(Fmt.price(p.target))，盈亏比约 \(rText)R。")
        } else {
            parts.append("触发价 \(Fmt.price(p.price))，失效位 \(Fmt.price(p.stopLoss))，目标 \(Fmt.price(p.target))，盈亏比约 \(rText)R。")
        }
        parts.append(invalidation(p))
        if !p.sizeNote.isEmpty {
            parts.append("仓位级别：\(p.sizeNote)。")
        }
        if p.isVetoed, !p.gateNote.isEmpty {
            parts.append("\(p.gateNote)。")
        }
        if p.isStrong {
            parts.append("多族信号同日共振，强度标记为强。")
        }
        return parts.joined(separator: "")
    }

    /// 失效条件：信号被证伪的明确标准。没有失效条件的信号不予展示。
    static func invalidation(_ p: TradePointSignal) -> String {
        switch p.kind {
        case .trendTemplateBreakout, .rangeBreakout, .secondWave:
            return "失效条件：收盘跌回突破位 \(Fmt.price(p.stopLoss)) 下方。"
        case .maPullback:
            return "失效条件：收盘跌破回踩均线并守不住止损 \(Fmt.price(p.stopLoss))。"
        case .momentumSurge:
            return "失效条件：动量转弱且收盘跌破止损 \(Fmt.price(p.stopLoss))。"
        case .confirmedReversal:
            return "失效条件：次日跌破止损 \(Fmt.price(p.stopLoss))（T+1 下当日无法卖出，跳空可能穿止损）。"
        case .meanReversion:
            return "失效条件：继续创 20 日新低或跌破止损 \(Fmt.price(p.stopLoss))。"
        case .trendBreakdown, .supportBreak:
            return "失效条件：收盘收回 \(Fmt.price(p.stopLoss)) 上方，破位不成立。"
        case .greedyTop:
            return "失效条件：收盘收回失效位 \(Fmt.price(p.stopLoss)) 上方，兑现信号解除。"
        }
    }

    /// 多点合并解释（用于榜单/面板的组合说明），按时间倒序、最多 3 条。
    static func explainBatch(_ points: [TradePointSignal], limit: Int = 3) -> String {
        var sorted = points
        sorted.sort { $0.date > $1.date }
        let top = Array(sorted.prefix(limit))
        var lines: [String] = []
        for p in top {
            lines.append(explain(p))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - LLM 提示词构造（纯函数，可单测）

/// 本地 LLM 只做解释层：输入是规则引擎已算好的信号 JSON，输出是自然语言说法。
/// 提示词强制"只引用给定数字、不许编造、不知道就拒绝"；输出还要过数字校验。
enum LLMPromptBuilder {

    static let systemPrompt = """
    你是 QuantLens 的信号解释助手。输入是规则引擎已算好的买卖点 JSON。
    铁律：只引用输入 JSON 里的数字，不许编造任何数字、不许新增信号、不许预测涨跌；
    不知道就说不知道。输出不超过 150 字中文，不出现“建议买入/卖出”“推荐”等措辞。
    """

    static func pointJSON(_ p: TradePointSignal) -> [String: Any] {
        var dict: [String: Any] = [
            "kind": p.kind.label,
            "code": p.kind.code,
            "direction": p.direction == .buy ? "buy" : "sell",
            "date": Fmt.date(p.date),
            "price": p.price,
            "strength": p.strength,
            "stopLoss": p.stopLoss,
            "target": p.target,
            "rMultiple": (p.rMultiple * 10).rounded() / 10,
            "atr": p.atr,
            "reason": p.reason,
            "isStrong": p.isStrong,
        ]
        if !p.sizeNote.isEmpty { dict["sizeNote"] = p.sizeNote }
        for (key, value) in p.evidence {
            dict[key] = (value * 100).rounded() / 100
        }
        return dict
    }

    /// 组合请求的 user 文本：JSON + 宽度快照（有则附）。
    static func userPayload(points: [TradePointSignal], breadth: MarketBreadth?) -> String {
        var sorted = points
        sorted.sort { $0.date > $1.date }
        let top = Array(sorted.prefix(3))
        var items: [[String: Any]] = []
        for p in top { items.append(pointJSON(p)) }
        var payload: [String: Any] = ["signals": items]
        if let b = breadth {
            payload["breadth"] = [
                "total": b.total,
                "advanceRatio": (b.advanceRatio * 1000).rounded() / 1000,
                "limitUp": b.limitUp,
                "limitDown": b.limitDown,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"signals\":[]}"
        }
        return text
    }

    /// OpenAI 兼容 Chat Completions 请求体（Ollama /v1/chat/completions 可直接用）。
    static func requestBody(points: [TradePointSignal],
                            breadth: MarketBreadth?,
                            model: String,
                            temperature: Double,
                            maxTokens: Int) -> [String: Any] {
        return [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPayload(points: points, breadth: breadth)],
            ],
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false,
        ]
    }
}

// MARK: - LLM 输出校验（纯函数，可单测）

/// 校验 LLM 文本里的每一个数字都出现在输入 JSON 里。LLM 算术不可靠、会编造，
/// 任何新数字出现即判定输出不可信，调用方回落到模板解释。
enum LLMOutputValidator {

    /// 从文本中提取全部数字（含小数与百分号前的数字，百分号本身去掉）。
    static func numbers(in text: String) -> [Double] {
        var out: [Double] = []
        let pattern = "-?\\d+(?:\\.\\d+)?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        for m in matches {
            guard let r = Range(m.range, in: text) else { continue }
            if let v = Double(text[r]) { out.append(v) }
        }
        return out
    }

    /// 逐个校验：文本数字必须在允许数字集合里（相对误差 0.5% 或绝对误差 0.011）。
    /// 数字 0、1、2 等小整数若在文本中作为序号出现也会被校验——提示词已要求
    /// 只引用给定数字，因此严格校验是符合设计的；模板回落保证永远有可用文本。
    static func isConsistent(_ text: String, allowedNumbers: [Double]) -> Bool {
        let found = numbers(in: text)
        for v in found {
            var matched = false
            for a in allowedNumbers {
                let tolerance = max(0.011, abs(a) * 0.005)
                if abs(v - a) <= tolerance { matched = true; break }
            }
            if !matched { return false }
        }
        return true
    }

    /// 从请求 JSON 文本中提取允许数字集合（即 LLM 可以引用的全部数字）。
    static func allowedNumbers(fromPayload payload: String) -> [Double] {
        numbers(in: payload)
    }
}
