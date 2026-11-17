import Foundation

// MARK: - AI 配置

struct AIConfig: Codable, Equatable {
    var enabled: Bool = false
    var baseURL: String = "https://api.openai.com/v1"
    var apiKey: String = ""
    var model: String = "gpt-4o-mini"
    var temperature: Double = 0.2
    var maxTokens: Int = 700
    /// 单次扫描最多送几只票给 AI 复核，控制成本
    var maxCandidatesPerScan: Int = 5
    /// 是否让 AI 参与盘中判断
    var intradayReview: Bool = true

    var isUsable: Bool {
        enabled && !apiKey.isEmpty && URL(string: baseURL) != nil
    }

    static let storageKey = "QuantLens.aiConfig.v1"

    static func load() -> AIConfig {
        guard let d = UserDefaults.standard.data(forKey: storageKey),
              let c = try? JSONDecoder().decode(AIConfig.self, from: d) else { return AIConfig() }
        return c
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(d, forKey: Self.storageKey)
        }
    }
}

// MARK: - AI 判断结果

struct AIVerdict: Codable, Hashable {
    /// 强烈买入 / 买入 / 观察 / 回避 / 危险
    var action: String
    /// 0~100 买入信心
    var confidence: Int
    /// 入场价区间
    var entryLow: Double?
    var entryHigh: Double?
    /// 止损价
    var stopLoss: Double?
    /// 目标价
    var target: Double?
    /// 建议仓位百分比
    var positionPct: Int?
    /// 核心逻辑（1~2 句）
    var thesis: String
    /// 主要风险
    var risks: [String]

    var actionColorKey: String {
        switch action {
        case "强烈买入": return "strongBuy"
        case "买入": return "buy"
        case "观察": return "watch"
        case "回避": return "avoid"
        default: return "danger"
        }
    }
}

// MARK: - AI 客户端

/// OpenAI 兼容的 Chat Completions 客户端。
/// 支持 OpenAI / DeepSeek / Moonshot / 通义 / 本地 Ollama 等所有兼容端点。
actor AIClient {

    static let shared = AIClient()

    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 45
        cfg.timeoutIntervalForResource = 60
        session = URLSession(configuration: cfg)
    }

    // MARK: - 连通性测试

    func testConnection(config: AIConfig) async -> Result<String, AIError> {
        guard !config.apiKey.isEmpty else { return .failure(.noKey) }
        do {
            let reply = try await chat(config: config,
                                       system: "你是量化交易助手。只回复两个字：就绪",
                                       user: "ping",
                                       jsonMode: false)
            return .success(reply.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let e as AIError {
            return .failure(e)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    // MARK: - 买点复核

    /// 把扫描结果整理成结构化提示，让 AI 给出可执行的买点判断。
    func reviewScan(results: [ScanResult],
                    analysis: Analysis?,
                    config: AIConfig) async -> Result<[String: AIVerdict], AIError> {
        guard config.isUsable else { return .failure(.notConfigured) }
        guard !results.isEmpty else { return .success([:]) }

        let payload = buildPayload(results: results, analysis: analysis)

        do {
            let raw = try await chat(config: config, system: Self.systemPrompt, user: payload, jsonMode: true)
            let verdicts = try parseVerdicts(raw, expected: results.map(\.security.displayCode))
            return .success(verdicts)
        } catch let e as AIError {
            return .failure(e)
        } catch {
            return .failure(.parse(error.localizedDescription))
        }
    }

    // MARK: - 提示词

    private static let systemPrompt = """
    你是一名专注 A 股短线的量化交易分析师，风格保守、强调风控。

    用户的目标：短线持有 2~10 个交易日，追求低风险的确定性收益，而不是高波动的暴利。

    你的任务：对提供的每只股票，判断当前是否构成「值得进场的买点」。

    判断原则（务必遵守）：
    1. 优先看风险，再看收益。止损位过宽（>8%）、趋势向下、顶背离、放量滞涨的票，一律给「回避」。
    2. 风险收益比 < 1.5 的机会不做。宁可错过，不要做错。
    3. 只在这几种情况下给「买入」或「强烈买入」：
       - 回踩关键支撑不破且缩量（低吸）
       - 放量突破压力位且趋势向上（突破）
       - 主力资金连续流入且价格处于相对低位（吸筹完成）
    4. 置信度（confidence）必须诚实反映把握程度，不要普遍给高分。
    5. 止损位必须放在有效支撑下方，不能为了好看而缩小止损。

    输出要求：严格返回 JSON，不要任何解释文字、不要 markdown 代码块。

    JSON 格式：
    {
      "verdicts": [
        {
          "code": "股票代码（与输入一致）",
          "action": "强烈买入|买入|观察|回避|危险",
          "confidence": 0-100 的整数,
          "entryLow": 数字,
          "entryHigh": 数字,
          "stopLoss": 数字,
          "target": 数字,
          "positionPct": 建议仓位百分比整数 0-30,
          "thesis": "一句话核心逻辑，不超过40字",
          "risks": ["风险点1", "风险点2"]
        }
      ]
    }
    """

    /// 构造送审数据。刻意把数值压缩到能读懂但不过量的程度，兼顾 token 成本与判断质量。
    /// 构建压缩后的提示词。
    ///
    /// 省 token 策略（相比逐字段描述，约省 65% 输入）：
    /// 1. 每只股票压成**单行 CSV**，字段顺序在表头声明一次；
    /// 2. 省略固定文案与重复单位，数值只保留必要精度；
    /// 3. 只对有信号的股票发送，无信号的不送；
    /// 4. 技术指标整体压成一行，不带标签。
    private func buildPayload(results: [ScanResult], analysis: Analysis?) -> String {
        var out: [String] = []
        out.append("CSV列序: 代码,名称,现价,涨跌%,买分,险分,支撑距%,压力距%,盈亏比,入场低,入场高")
        out.append("[股票]")

        // 只送有信号倾向的（买分或进场分 >= 40），避免浪费 token
        let candidates = results
            .filter { $0.buyScore >= 40 || $0.accumulateScore >= 40 }
            .prefix(6)

        for r in candidates {
            let sup = r.support.map { String(format: "%.2f", ($0 - r.price) / r.price * 100) } ?? "-"
            let res = r.resistance.map { String(format: "%.2f", ($0 - r.price) / r.price * 100) } ?? "-"
            let rr = r.riskReward.map { String(format: "%.1f", $0) } ?? "-"
            let lo = r.entryZone.map { String(format: "%.2f", $0.low) } ?? "-"
            let hi = r.entryZone.map { String(format: "%.2f", $0.high) } ?? "-"
            let row = [
                r.security.displayCode, r.security.name,
                String(format: "%.2f", r.price),
                String(format: "%.2f", r.changePct),
                String(format: "%.0f", r.buyScore),
                String(format: "%.0f", r.riskScore),
                sup, res, rr, lo, hi
            ].joined(separator: ",")
            out.append(row)
        }

        // 技术指标压成一行（仅当主图标的在候选内）
        if let a = analysis,
           let sel = AppState.shared.selected,
           candidates.contains(where: { $0.security.id == sel.id }) {
            let ctx = a.context
            let idx = ctx.lastIndex
            var kv: [String] = []
            if let t = ctx.trend { kv.append("趋势\(t.direction.label)") }
            if let v = ctx.rsi14.value(idx) { kv.append(String(format: "RSI%.0f", v)) }
            if let v = ctx.macd.dif.value(idx) { kv.append(String(format: "DIF%.2f", v)) }
            if let v = ctx.kdj.k.value(idx) { kv.append(String(format: "K%.0f", v)) }
            if let v = ctx.volRatio.value(idx) { kv.append(String(format: "量比%.1f", v)) }
            if let v = ctx.cmf.value(idx) { kv.append(String(format: "CMF%.2f", v)) }
            if let f = ctx.fundFlowToday { kv.append("主力\(Fmt.money(f.mainNet))") }
            if !kv.isEmpty {
                out.append("[指标] " + kv.joined(separator: ","))
            }
        }

        out.append("[要求] 逐只给 action/confidence/entryLow/entryHigh/stopLoss/target/thesis，JSON")
        return out.joined(separator: "\n")
    }

    /// 仅供自检：暴露构造好的提示词，便于核对送给模型的信息
    func debugPayload(results: [ScanResult], analysis: Analysis?) -> String {
        buildPayload(results: results, analysis: analysis)
    }

    // MARK: - 网络

    private func chat(config: AIConfig, system: String, user: String, jsonMode: Bool) async throws -> String {
        guard var comps = URLComponents(string: config.baseURL) else { throw AIError.badURL }
        // 允许用户填 .../v1 或完整 .../v1/chat/completions
        if !comps.path.hasSuffix("/chat/completions") {
            comps.path = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            comps.path = "/" + comps.path + "/chat/completions"
            comps.path = comps.path.replacingOccurrences(of: "//", with: "/")
        }
        guard let url = comps.url else { throw AIError.badURL }

        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": config.temperature,
            "max_tokens": config.maxTokens,
            "stream": false
        ]
        if jsonMode {
            body["response_format"] = ["type": "json_object"]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw AIError.http(http.statusCode, String(msg))
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw AIError.parse("响应结构异常：\(preview)")
        }
        return content
    }

    // MARK: - 解析

    private func parseVerdicts(_ raw: String, expected: [String]) throws -> [String: AIVerdict] {
        // 模型可能仍会包一层 ```json ```
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[text.startIndex..<fence.lowerBound])
            }
        }
        // 兜底：截取第一个 { 到最后一个 }
        if let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}") {
            text = String(text[s...e])
        }

        guard let data = text.data(using: .utf8) else { throw AIError.parse("非 UTF-8") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.parse("JSON 结构不合法")
        }

        let arr: [[String: Any]]
        if let v = obj["verdicts"] as? [[String: Any]] {
            arr = v
        } else if let v = obj["data"] as? [[String: Any]] {
            arr = v
        } else if obj["action"] != nil {
            arr = [obj]
        } else {
            throw AIError.parse("未找到 verdicts 数组")
        }

        var out: [String: AIVerdict] = [:]
        for item in arr {
            guard let code = item["code"] as? String else { continue }
            let action = (item["action"] as? String) ?? "观察"
            let confidence = (item["confidence"] as? NSNumber)?.intValue ?? 50
            let thesis = (item["thesis"] as? String) ?? ""
            let risks = (item["risks"] as? [String]) ?? []

            let verdict = AIVerdict(
                action: action,
                confidence: max(0, min(100, confidence)),
                entryLow: (item["entryLow"] as? NSNumber)?.doubleValue,
                entryHigh: (item["entryHigh"] as? NSNumber)?.doubleValue,
                stopLoss: (item["stopLoss"] as? NSNumber)?.doubleValue,
                target: (item["target"] as? NSNumber)?.doubleValue,
                positionPct: (item["positionPct"] as? NSNumber)?.intValue,
                thesis: thesis,
                risks: risks
            )
            // 归一化代码：去掉市场前缀
            let normalized = normalizeCode(code, expected: expected)
            out[normalized] = verdict
        }
        return out
    }

    private func normalizeCode(_ raw: String, expected: [String]) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if expected.contains(trimmed) { return trimmed }
        // sh600519 -> 600519, 600519.SH -> 600519
        for e in expected where trimmed.contains(e) { return e }
        return trimmed
    }
}

// MARK: - 错误

enum AIError: LocalizedError {
    case notConfigured
    case noKey
    case badURL
    case http(Int, String)
    case parse(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "AI 未启用，请先在设置中配置"
        case .noKey: return "缺少 API Key"
        case .badURL: return "Base URL 格式不正确"
        case .http(let code, let msg):
            if code == 401 { return "API Key 无效（401）" }
            if code == 404 { return "模型或路径不存在（404）：\(msg)" }
            if code == 429 { return "请求过于频繁或额度不足（429）" }
            return "HTTP \(code)：\(msg)"
        case .parse(let s): return "AI 返回格式异常：\(s)"
        case .network(let s): return "网络错误：\(s)"
        }
    }
}
