import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - 云端模型配置

/// 云端 LLM（OpenAI 兼容 Chat Completions）配置。默认关闭，用户手动开启并填 Key。
///
/// 与本地 Ollama 客户端共用同一套护栏（提示词铁律 + 数字校验 + 模板回落），
/// 区别只在传输层：云端请求带 Authorization 头、超时 30 秒。
/// API Key 不存在本结构里，只存系统 Keychain（见 `loadKey`/`saveKey`）。
struct CloudLLMConfig: Codable, Equatable {

    enum Preset: String, Codable, CaseIterable {
        case deepseek
        case dashscope
        case custom

        var label: String {
            switch self {
            case .deepseek: return "DeepSeek"
            case .dashscope: return "通义百炼"
            case .custom: return "自定义"
            }
        }

        var baseURL: String {
            switch self {
            case .deepseek: return "https://api.deepseek.com/v1"
            case .dashscope: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
            case .custom: return ""
            }
        }

        var model: String {
            switch self {
            case .deepseek: return "deepseek-chat"
            case .dashscope: return "qwen-plus"
            case .custom: return ""
            }
        }
    }

    var enabled: Bool = false
    var preset: Preset = .deepseek
    var baseURL: String = Preset.deepseek.baseURL
    var model: String = Preset.deepseek.model
    var temperature: Double = 0
    var maxTokens: Int = 250
    var timeoutSeconds: Double = 30

    /// 可用 = 开关开 + 地址合法 + 模型名非空。Key 是否存在另由 `hasKey()` 判断。
    var isUsable: Bool {
        enabled && URL(string: baseURL) != nil && !baseURL.isEmpty && !model.isEmpty
    }

    /// Chat Completions 端点
    var chatURL: URL? {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if base.isEmpty { return nil }
        return URL(string: base + "/chat/completions")
    }

    /// 模型列表端点（连通性检查用，只发 GET，不消耗 token）
    var modelsURL: URL? {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if base.isEmpty { return nil }
        return URL(string: base + "/models")
    }

    static let storageKey = "QuantLens.cloudLLM.v1"
    static let keychainService = "QuantLens.CloudLLM"
    static let keychainAccount = "apiKey"

    static func load() -> CloudLLMConfig {
        guard let d = UserDefaults.standard.data(forKey: storageKey),
              let c = try? JSONDecoder().decode(CloudLLMConfig.self, from: d) else { return CloudLLMConfig() }
        return c
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(d, forKey: Self.storageKey)
        }
    }

    // MARK: Key（只进 Keychain）

    static func loadKey() -> String? {
        KeychainStore.load(service: keychainService, account: keychainAccount)
    }

    static func saveKey(_ key: String) -> Bool {
        KeychainStore.save(key, service: keychainService, account: keychainAccount)
    }

    static func deleteKey() {
        KeychainStore.delete(service: keychainService, account: keychainAccount)
    }

    static func hasKey() -> Bool {
        guard let k = loadKey() else { return false }
        return !k.isEmpty
    }
}

// MARK: - 云端 LLM 客户端（解释层，绝不参与决策）

/// 与 `LocalLLMClient` 相同的护栏，不同的传输层：
/// 1. 输入只收规则引擎已算好的信号 JSON，输出只作文字说明，永不回流到评分、仓位或止损；
/// 2. 温度固定 0、输出上限 250 token、超时 30 秒；
/// 3. 输出过数字校验：任何输入 JSON 里没有的数字 → 丢弃全文，回落模板解释；
/// 4. 端点不通、鉴权失败、超时、解析失败 → 全部回落模板解释，App 功能不受影响。
/// 隐私：信号 JSON 会发给所选服务商（见 README），Key 只读自 Keychain、只进请求头。
actor CloudLLMClient {

    static let shared = CloudLLMClient()

    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 35
        cfg.timeoutIntervalForResource = 40
        session = URLSession(configuration: cfg)
    }

    /// 构造 Chat Completions 请求（纯函数，可单测）。Key 只进 Authorization 头。
    static func makeChatRequest(url: URL, apiKey: String, body: [String: Any],
                                timeout: Double) -> URLRequest? {
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        req.httpBody = bodyData
        req.timeoutInterval = timeout
        return req
    }

    /// 构造连通性检查请求：GET /models（纯函数，可单测）。
    static func makeModelsRequest(url: URL, apiKey: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        return req
    }

    /// 连通性检查：GET /models，10 秒超时。只判断端点与 Key 是否有效，不消耗 token。
    func checkAvailable(config: CloudLLMConfig, apiKey: String) async -> Bool {
        guard !apiKey.isEmpty, let url = config.modelsURL else { return false }
        let req = Self.makeModelsRequest(url: url, apiKey: apiKey)
        do {
            let (_, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// 解释一组买卖点。成功且校验通过返回云端文本，否则返回模板文本。
    /// 返回值附带来源标记，供界面注明"云端模型"或"模板"。
    func explain(points: [TradePointSignal],
                 breadth: MarketBreadth?,
                 config: CloudLLMConfig,
                 apiKey: String) async -> (text: String, fromLLM: Bool) {
        let fallback = SignalExplainer.explainBatch(points)
        guard config.isUsable, !apiKey.isEmpty, !points.isEmpty else { return (fallback, false) }
        guard let url = config.chatURL else { return (fallback, false) }

        let body = LLMPromptBuilder.requestBody(
            points: points, breadth: breadth,
            model: config.model, temperature: config.temperature, maxTokens: config.maxTokens
        )
        guard let req = Self.makeChatRequest(url: url, apiKey: apiKey, body: body,
                                             timeout: config.timeoutSeconds) else {
            return (fallback, false)
        }

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return (fallback, false)
            }
            guard let text = LocalLLMClient.parseContent(data) else { return (fallback, false) }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return (fallback, false) }
            // 数字校验：云端文本里的数字必须全部来自输入 JSON（与本地同一口径）
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
}
