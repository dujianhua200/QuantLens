import Foundation

// MARK: - 错误

enum DataError: LocalizedError {
    case badURL
    case http(Int)
    case decode(String)
    case empty(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "URL 构造失败"
        case .http(let code): return "HTTP \(code)"
        case .decode(let s): return "解析失败：\(s)"
        case .empty(let s): return "无数据：\(s)"
        case .network(let s): return "网络错误：\(s)"
        }
    }
}

// MARK: - HTTP 客户端

/// 轻量 HTTP 客户端。免费行情接口对 UA / Referer 敏感，
/// 这里统一伪装成浏览器，并对 GBK 响应做编码探测。
final class HTTPClient {
    static let shared = HTTPClient()

    private let session: URLSession
    private let lock = NSLock()
    private var lastRequestAt: [String: Date] = [:]

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 20
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // 部分免费接口需要走系统代理才能访问
        cfg.connectionProxyDictionary = nil
        session = URLSession(configuration: cfg)
    }

    private static let userAgents = [
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    ]

    /// 同一 host 的最小请求间隔，避免触发风控
    /// 限速。注意：不能持锁 sleep，否则会把并发请求全部串行化并卡死 actor。
    func throttle(host: String, interval: TimeInterval = 0.35) async {
        lock.lock()
        let now = Date()
        let last = lastRequestAt[host] ?? .distantPast
        let wait = max(0, interval - now.timeIntervalSince(last))
        // 先占位，避免并发请求看到同一个旧时间戳
        lastRequestAt[host] = now.addingTimeInterval(wait)
        lock.unlock()

        if wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    /// 批量接口专用：一次请求覆盖几十上百只标的，跳过 host 间隔限速。
    /// 仅用于腾讯批量行情（`q=` 多代码），单次调用已等价于数十次单票请求。
    func batchData(from urlString: String, referer: String = "https://gu.qq.com/") async throws -> Data {
        guard let url = URL(string: urlString) else { throw DataError.badURL }
        var lastError: Error = DataError.network("未发起请求")
        for attempt in 0..<2 {
            var req = URLRequest(url: url)
            req.setValue(Self.userAgents[attempt % Self.userAgents.count], forHTTPHeaderField: "User-Agent")
            req.setValue(referer, forHTTPHeaderField: "Referer")
            req.setValue("*/*", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await session.data(for: req)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    lastError = DataError.http(http.statusCode)
                    continue
                }
                guard !data.isEmpty else {
                    lastError = DataError.empty(url.lastPathComponent)
                    continue
                }
                return data
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        throw DataError.network(lastError.localizedDescription)
    }

    func data(from urlString: String, referer: String = "https://quote.eastmoney.com/") async throws -> Data {
        guard let url = URL(string: urlString) else { throw DataError.badURL }
        if let host = url.host { await throttle(host: host) }

        var lastError: Error = DataError.network("未发起请求")
        for attempt in 0..<2 {
            var req = URLRequest(url: url)
            req.setValue(Self.userAgents[attempt % Self.userAgents.count], forHTTPHeaderField: "User-Agent")
            req.setValue(referer, forHTTPHeaderField: "Referer")
            req.setValue("*/*", forHTTPHeaderField: "Accept")
            req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
            do {
                let (data, response) = try await session.data(for: req)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    lastError = DataError.http(http.statusCode)
                    continue
                }
                guard !data.isEmpty else {
                    lastError = DataError.empty(url.lastPathComponent)
                    continue
                }
                return data
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        throw DataError.network(lastError.localizedDescription)
    }

    /// 处理 GBK / UTF-8 混合编码的响应
    func string(from data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        let gbk = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gbk)) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    func json(from urlString: String, referer: String = "https://quote.eastmoney.com/") async throws -> Any {
        let d = try await data(from: urlString, referer: referer)
        do {
            return try JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
        } catch {
            let preview = string(from: d).prefix(120)
            throw DataError.decode("非 JSON 响应：\(preview)")
        }
    }
}
