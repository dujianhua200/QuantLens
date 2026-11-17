import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - 本地模型配置

/// 本地 LLM（Ollama 兼容端点）配置。默认关闭，用户在设置里手动开启。
///
/// 模型不捆绑、不下载：用户自己装 Ollama 并 `ollama pull qwen2.5:3b`。
/// 8GB 内存只能跑 3B 级模型，7B 会换页卡顿（见 README）。
struct LocalLLMConfig: Codable, Equatable {
    var enabled: Bool = false
    var baseURL: String = "http://localhost:11434/v1"
    var model: String = "qwen2.5:3b"
    var temperature: Double = 0
    var maxTokens: Int = 250
    var timeoutSeconds: Double = 20

    var isUsable: Bool {
        enabled && URL(string: baseURL) != nil && !model.isEmpty
    }

    /// Chat Completions 端点
    var chatURL: URL? {
        URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions")
    }

    /// 模型列表端点（连通性检查用）
    var modelsURL: URL? {
        URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models")
    }

    static let storageKey = "QuantLens.localLLM.v1"

    static func load() -> LocalLLMConfig {
        guard let d = UserDefaults.standard.data(forKey: storageKey),
              let c = try? JSONDecoder().decode(LocalLLMConfig.self, from: d) else { return LocalLLMConfig() }
        return c
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(d, forKey: Self.storageKey)
        }
    }
}

// MARK: - 本地 LLM 客户端（解释层，绝不参与决策）

/// Ollama 兼容的 Chat Completions 客户端，只做信号解释。
///
/// 安全边界（硬性）：
/// 1. 输入只收规则引擎已算好的信号 JSON，输出只作文字说明，永不回流到评分、仓位或止损；
/// 2. 温度固定 0、输出上限 250 token、超时 20 秒；
/// 3. 输出过数字校验：任何输入 JSON 里没有的数字 → 丢弃全文，回落模板解释；
/// 4. 端点不通、超时、解析失败 → 全部回落模板解释，App 功能不受影响。
actor LocalLLMClient {

    static let shared = LocalLLMClient()

    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 30
        session = URLSession(configuration: cfg)
    }

    /// 连通性检查：GET /models，5 秒超时。只判断端点是否活着，不判断模型是否已下载。
    func checkAvailable(config: LocalLLMConfig) async -> Bool {
        guard let url = config.modelsURL else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 5
        do {
            let (_, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// 解释一组买卖点。成功且校验通过返回 LLM 文本，否则返回模板文本。
    /// 返回值附带来源标记，供界面注明"本地模型"或"模板"。
    func explain(points: [TradePointSignal],
                 breadth: MarketBreadth?,
                 config: LocalLLMConfig) async -> (text: String, fromLLM: Bool) {
        let fallback = SignalExplainer.explainBatch(points)
        guard config.isUsable, !points.isEmpty else { return (fallback, false) }
        guard let url = config.chatURL else { return (fallback, false) }

        let body = LLMPromptBuilder.requestBody(
            points: points, breadth: breadth,
            model: config.model, temperature: config.temperature, maxTokens: config.maxTokens
        )
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return (fallback, false)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        req.timeoutInterval = config.timeoutSeconds

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return (fallback, false)
            }
            guard let text = Self.parseContent(data) else { return (fallback, false) }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return (fallback, false) }
            // 数字校验：LLM 文本里的数字必须全部来自输入 JSON
            let payload = LLMPromptBuilder.userPayload(points: points, breadth: breadth)
            let allowed = LLMOutputValidator.allowedNumbers(fromPayload: payload)
            guard LLMOutputValidator.isConsistent(trimmed, allowedNumbers: allowed) else {
                return (fallback, false)
            }
            return (trimmed, true)
        } catch {
            return (fallback, false)
        }
    }

    /// 解析 OpenAI 兼容响应：choices[0].message.content（纯函数，可单测）。
    static func parseContent(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let choices = obj["choices"] as? [[String: Any]] else { return nil }
        guard let first = choices.first else { return nil }
        guard let message = first["message"] as? [String: Any] else { return nil }
        guard let content = message["content"] as? String else { return nil }
        return content
    }
}
