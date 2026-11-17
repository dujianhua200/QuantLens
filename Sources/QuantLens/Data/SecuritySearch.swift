import Foundation

// MARK: - 搜索结果

struct SearchHit: Identifiable, Hashable {
    var security: Security
    var relevance: Double      // 0~1，用于排序
    var kindLabel: String      // 显示的类型标签

    var id: String { security.id }
}

// MARK: - 证券类型

enum SecurityKind: String {
    case stockA = "A股"
    case stockHK = "港股"
    case stockUS = "美股"
    case stockBJ = "北交所"
    case index = "指数"

    var sortWeight: Int {
        switch self {
        case .stockA: return 6
        case .stockBJ: return 5
        case .stockHK: return 3
        case .stockUS: return 3
        case .index: return 1
        }
    }
}

// MARK: - 搜索服务

/// 腾讯 smartbox 搜索的封装。
///
/// 原始接口返回的字段用 `\uXXXX` 转义（GBK 响应里嵌套了 Unicode 转义），
/// 直接使用会显示成 `\u8d35\u5dde\u8305\u53f0` 这样的乱码，
/// 必须显式解码。同时接口会返回大量 ETF / 开放式基金 / 债券 / 权证，
/// 需要按类型过滤，并按「代码精确 > 名称精确 > 名称前缀 > 拼音首字母 > 包含」排序。
actor SecuritySearchService {

    static let shared = SecuritySearchService()

    private var cache: [String: [SearchHit]] = [:]
    private let cacheLimit = 60

    /// 只保留可交易的股票与指数。
    /// 腾讯的类型是带后缀的，科创板是 `GP-A-KCB`、创业板是 `GP-A-CYB`，
    /// 必须用前缀匹配，精确匹配会把科创板和创业板全部漏掉。
    private static let allowedTypePrefixes = ["GP-A", "GP-B", "GP", "ZS"]
    /// 明确排除的类型：权证、牛熊证、基金、债券、期货
    private static let blockedTypePrefixes = ["QZ", "KJ", "ETF", "JJ", "ZQ", "QH", "CZ"]

    private func isAllowed(_ type: String) -> Bool {
        for b in Self.blockedTypePrefixes where type.hasPrefix(b) { return false }
        return Self.allowedTypePrefixes.contains { type.hasPrefix($0) }
    }

    func search(_ keyword: String) async -> [SearchHit] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return [] }

        let key = kw.lowercased()
        if let cached = cache[key] { return cached }

        let raw = await fetchRaw(kw)
        let hits = rank(raw, keyword: kw)

        if cache.count >= cacheLimit { cache.removeAll() }
        cache[key] = hits
        return hits
    }

    // MARK: - 拉取

    private func fetchRaw(_ keyword: String) async -> [(market: String, code: String, name: String, pinyin: String, type: String)] {
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return [] }
        let url = "https://smartbox.gtimg.cn/s3/?q=\(encoded)&t=all"

        guard let data = try? await HTTPClient.shared.data(from: url, referer: "https://gu.qq.com/") else { return [] }
        let text = HTTPClient.shared.string(from: data)

        guard let q1 = text.firstIndex(of: "\""),
              let q2 = text.lastIndex(of: "\""), q1 < q2 else { return [] }
        let payload = String(text[text.index(after: q1)..<q2])
        guard payload != "N", !payload.isEmpty else { return [] }

        var out: [(String, String, String, String, String)] = []
        for entry in payload.components(separatedBy: "^") {
            let parts = entry.components(separatedBy: "~")
            guard parts.count >= 5 else { continue }
            let name = Self.unescapeUnicode(parts[2])
            out.append((parts[0], parts[1], name, parts[3], parts[4]))
        }
        return out
    }

    /// 解码 `\uXXXX` 序列。用 JSON 解析器做，比手写状态机稳。
    static func unescapeUnicode(_ s: String) -> String {
        guard s.contains("\\u") else { return s }
        let wrapped = "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
        if let data = wrapped.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String {
            return decoded
        }
        // 退化路径：手工扫描
        var out = ""
        var idx = s.startIndex
        while idx < s.endIndex {
            if s[idx] == "\\", s.index(after: idx) < s.endIndex, s[s.index(after: idx)] == "u" {
                let hexStart = s.index(idx, offsetBy: 2)
                if let hexEnd = s.index(hexStart, offsetBy: 4, limitedBy: s.endIndex) {
                    let hex = String(s[hexStart..<hexEnd])
                    if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                        out.append(Character(scalar))
                        idx = hexEnd
                        continue
                    }
                }
            }
            out.append(s[idx])
            idx = s.index(after: idx)
        }
        return out
    }

    // MARK: - 过滤与排序

    private func rank(_ raw: [(market: String, code: String, name: String, pinyin: String, type: String)],
                      keyword: String) -> [SearchHit] {
        let kw = keyword.lowercased()
        var hits: [SearchHit] = []

        for item in raw {
            // 1. 类型过滤
            guard isAllowed(item.type) else { continue }

            // 2. 代码形态校验，拦住数据异常
            guard let resolved = resolve(market: item.market, code: item.code, name: item.name) else { continue }

            // 3. 相关性
            let codeLower = item.code.lowercased()
            let symbolLower = resolved.security.symbol.lowercased()
            let nameLower = item.name.lowercased()
            let pinyinLower = item.pinyin.lowercased()

            var score = 0.0
            if codeLower == kw || symbolLower == kw {
                score = 1.0                                    // 代码完全命中
            } else if nameLower == kw {
                score = 0.95                                   // 名称完全命中
            } else if pinyinLower == kw {
                score = 0.88                                   // 拼音首字母完全命中
            } else if codeLower.hasPrefix(kw) || symbolLower.hasPrefix(kw) {
                score = 0.80                                   // 代码前缀
            } else if nameLower.hasPrefix(kw) {
                score = 0.75                                   // 名称前缀
            } else if pinyinLower.hasPrefix(kw) {
                score = 0.62                                   // 拼音前缀
            } else if nameLower.contains(kw) {
                score = 0.50                                   // 名称包含
            } else if codeLower.contains(kw) {
                score = 0.40                                   // 代码包含
            } else {
                continue
            }

            // 4. 同分时按市场偏好：A股 > 北交所 > 港股/美股 > 指数
            let kind = SecurityKind(rawValue: resolved.kindLabel) ?? .stockA
            let marketBias = Double(kind.sortWeight) * 0.020
            score += marketBias

            hits.append(SearchHit(security: resolved.security,
                                  relevance: min(score, 1.0),
                                  kindLabel: resolved.kindLabel))
        }

        // 去重（同一 security.id 只留最高分）
        var seen: [String: SearchHit] = [:]
        for h in hits {
            if let existing = seen[h.security.id], existing.relevance >= h.relevance { continue }
            seen[h.security.id] = h
        }

        return seen.values
            .sorted {
                if abs($0.relevance - $1.relevance) > 0.001 { return $0.relevance > $1.relevance }
                return $0.security.displayCode < $1.security.displayCode
            }
            .prefix(12)
            .map { $0 }
    }

    // MARK: - 归一化

    private func resolve(market: String, code: String, name: String) -> (security: Security, kindLabel: String)? {
        switch market {
        case "sh":
            // 指数：000xxx / 999xxx；股票：60xxxx / 68xxxx / 900xxx
            if code.hasPrefix("000") || code.hasPrefix("999") {
                return (Security(symbol: "sh\(code)", name: name, market: .index), SecurityKind.index.rawValue)
            }
            guard code.hasPrefix("60") || code.hasPrefix("68") || code.hasPrefix("900") else { return nil }
            return (Security(symbol: code, name: name, market: .sh), SecurityKind.stockA.rawValue)

        case "sz":
            if code.hasPrefix("399") {
                return (Security(symbol: "sz\(code)", name: name, market: .index), SecurityKind.index.rawValue)
            }
            guard code.hasPrefix("00") || code.hasPrefix("30") || code.hasPrefix("20") else { return nil }
            return (Security(symbol: code, name: name, market: .sz), SecurityKind.stockA.rawValue)

        case "bj":
            return (Security(symbol: code, name: name, market: .bj), SecurityKind.stockBJ.rawValue)

        case "hk":
            // 港股：去掉市场后缀，保留 5 位数字；排除牛熊证（8 开头的 5 位是衍生品）
            guard code.count <= 5, code.allSatisfy(\.isNumber) else { return nil }
            if code.hasPrefix("8") { return nil }     // 港股 8xxxx 多为衍生权证
            let symbol = String(repeating: "0", count: max(0, 5 - code.count)) + code
            return (Security(symbol: symbol, name: name, market: .hk), SecurityKind.stockHK.rawValue)

        case "us":
            // aapl.oq -> AAPL
            let symbol = code.components(separatedBy: ".").first?.uppercased() ?? code.uppercased()
            guard !symbol.isEmpty, symbol.allSatisfy({ $0.isLetter || $0 == "." || $0 == "-" }) else { return nil }
            return (Security(symbol: symbol, name: name, market: .us), SecurityKind.stockUS.rawValue)

        default:
            return nil
        }
    }
}
