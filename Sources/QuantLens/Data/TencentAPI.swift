import Foundation

// MARK: - 腾讯行情（主数据源：实时快照 + 多周期K线 + 代码搜索）

/// 腾讯免费行情接口，无需 token，支持 A股 / 北交所 / 港股 / 美股 / 指数。
/// 实测稳定性明显优于东财，作为主数据源。
actor TencentAPI {

    static let shared = TencentAPI()

    private let quoteFields = 60

    // MARK: 实时快照

    func quotes(codes: [String]) async throws -> [String: Quote] {
        guard !codes.isEmpty else { return [:] }
        var result: [String: Quote] = [:]
        // 腾讯单次请求建议不超过 60 个代码
        for chunk in codes.chunked(into: 50) {
            let joined = chunk.joined(separator: ",")
            let url = "https://qt.gtimg.cn/q=\(joined)"
            let data = try await HTTPClient.shared.data(from: url, referer: "https://gu.qq.com/")
            let text = HTTPClient.shared.string(from: data)

            for line in text.split(separator: ";") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("v_"),
                      let eq = trimmed.firstIndex(of: "="),
                      let q1 = trimmed.firstIndex(of: "\"") else { continue }
                let key = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<eq])
                guard let q2 = trimmed.lastIndex(of: "\""), q1 < q2 else { continue }
                let payload = String(trimmed[trimmed.index(after: q1)..<q2])
                let f = payload.components(separatedBy: "~")
                guard f.count > 45 else { continue }
                var sec = SecurityFactory.fromTencentKey(key)
                // 实时接口的名称字段是纯中文，但历史版本可能带 \uXXXX 转义，统一清洗
                let rawName = f.count > 1 ? f[1] : ""
                sec = Security(symbol: sec.symbol,
                               name: SecuritySearchService.unescapeUnicode(rawName),
                               market: sec.market)
                if let quote = Self.parseQuote(fields: f, security: sec) {
                    // 统一用 Security.id 作为 key，与 AppState.quotes / SidebarView 查询口径一致
                    result[sec.id] = quote
                }
            }
        }
        return result
    }

    private static func d(_ s: String) -> Double {
        Double(s) ?? 0
    }

    private static func parseQuote(fields f: [String], security: Security) -> Quote? {
        guard f.count > 35 else { return nil }
        let price = d(f[3])
        let prev = d(f[4])
        guard price > 0 || prev > 0 else { return nil }

        var ts = Date()
        if f.count > 30, f[30].count >= 14 {
            ts = parseTimestamp(f[30]) ?? Date()
        }

        var turnover = f.count > 38 ? d(f[38]) : 0
        var pe = f.count > 39 ? d(f[39]) : 0
        var amp = f.count > 43 ? d(f[43]) : 0
        var floatCap = f.count > 44 ? d(f[44]) : 0
        var totalCap = f.count > 45 ? d(f[45]) : 0
        var pb = f.count > 46 ? d(f[46]) : 0
        let volume = d(f[6])
        var amount = f.count > 37 ? d(f[37]) * 1e4 : 0

        // 部分市场字段位偏移不同，做兜底
        if amp == 0, prev > 0, let hi = Double(f[33]), let lo = Double(f[34]), hi > 0 {
            amp = (hi - lo) / prev * 100
        }
        if totalCap == 0, floatCap > 0 { totalCap = floatCap }
        if amount == 0, f.count > 35 {
            let parts = f[35].components(separatedBy: "/")
            if parts.count >= 3 { amount = d(parts[2]) }
        }
        // 港股/美股无涨跌停，字段为空
        if !turnover.isFinite { turnover = 0 }
        if !pe.isFinite { pe = 0 }
        if !pb.isFinite { pb = 0 }

        return Quote(
            security: security,
            price: price,
            prevClose: prev,
            open: d(f[5]),
            high: f.count > 33 ? d(f[33]) : price,
            low: f.count > 34 ? d(f[34]) : price,
            volume: volume,
            amount: amount,
            turnoverRate: turnover,
            pe: pe,
            pb: pb,
            totalMarketCap: totalCap,
            floatMarketCap: floatCap,
            amplitude: amp,
            timestamp: ts
        )
    }

    private static func parseTimestamp(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        // A股 20261113161455 / 港股 2026/11/13 18:31:15 / 美股 2026-11-13 17:15:59
        for fmt in ["yyyyMMddHHmmss", "yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyyMMddHHmm"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    // MARK: K线

    /// 拉取K线。按「腾讯 → 新浪」回退，并保证返回足够的历史长度。
    ///
    /// 已知的数据源限制（实测）：
    /// - 腾讯 `qfq` 前复权参数在美股/港股会截断历史（美股只剩首末 2 根）
    /// - 腾讯北交所只有当日数据
    /// - 分钟线仅 A股（沪深）支持
    func candles(for security: Security, period: KPeriod, count: Int = 800) async throws -> [Candle] {
        let code = security.tencentCode
        let minBars = 60

        // 分钟线：仅沪深A股有
        if period.isIntraday {
            if security.market == .sh || security.market == .sz {
                if let bars = try? await minuteCandles(code: code, period: period, count: count),
                   bars.count >= minBars {
                    return bars
                }
            }
            // 其它市场（及分钟线失败）回退日线
            return try await dailyCandlesWithFallback(security: security, period: .day, count: count)
        }

        return try await dailyCandlesWithFallback(security: security, period: period, count: count)
    }

    /// 日/周/月线：腾讯优先，不足则用新浪补齐
    private func dailyCandlesWithFallback(security: Security, period: KPeriod, count: Int) async throws -> [Candle] {
        let code = security.tencentCode
        var bars: [Candle] = []
        if let t = try? await dailyCandles(code: code, period: period, count: count) {
            bars = t
        }

        // 腾讯的历史不足时走新浪（新浪只有日线，周/月线由日线合成）
        if bars.count < 60 {
            switch security.market {
            case .us:
                if let s = try? await SinaKlineAPI.shared.usDaily(symbol: security.symbol, limit: max(count, 600)),
                   s.count > bars.count {
                    bars = s
                }
            case .sh, .sz, .bj:
                if let s = try? await SinaKlineAPI.shared.cnDaily(code: code, limit: max(count, 600)),
                   s.count > bars.count {
                    bars = s
                }
            case .hk, .index:
                // 港股/指数：腾讯去掉 qfq 已有长历史，这里再兜一次
                if let t = try? await dailyCandles(code: code, period: period, count: count, useQFQ: false),
                   t.count > bars.count {
                    bars = t
                }
            }
        }

        // 周/月线聚合
        if period == .week || period == .month, !bars.isEmpty {
            let daily = bars.count >= 60 ? bars : ((try? await dailyCandles(code: code, period: .day, count: count, useQFQ: false)) ?? bars)
            return aggregate(daily, period: period)
        }
        return bars
    }

    /// 把日线合成为周线 / 月线
    private func aggregate(_ daily: [Candle], period: KPeriod) -> [Candle] {
        guard !daily.isEmpty else { return [] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var groups: [(key: Date, bars: [Candle])] = []
        var currentKey: Date?

        for c in daily.sorted(by: { $0.date < $1.date }) {
            let comps: DateComponents?
            switch period {
            case .week:
                // 周一分组的 ISO 周
                comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: c.date)
            default:
                comps = cal.dateComponents([.year, .month], from: c.date)
            }
            guard let comps, let key = cal.date(from: comps) else { continue }
            if currentKey != key {
                groups.append((key, [c]))
                currentKey = key
            } else {
                groups[groups.count - 1].bars.append(c)
            }
        }

        return groups.map { g in
            let first = g.bars.first!
            let last = g.bars.last!
            return Candle(
                date: last.date,
                open: first.open,
                high: g.bars.map(\.high).max() ?? last.high,
                low: g.bars.map(\.low).min() ?? last.low,
                close: last.close,
                volume: g.bars.map(\.volume).reduce(0, +),
                amount: g.bars.map(\.amount).reduce(0, +)
            )
        }
    }

    private func minuteCandles(code: String, period: KPeriod, count: Int) async throws -> [Candle] {
        let p = period.rawValue  // m5 / m15 / m30 / m60
        let url = "https://ifzq.gtimg.cn/appstock/app/kline/mkline?param=\(code),\(p),,\(count)"
        let obj = try await HTTPClient.shared.json(from: url, referer: "https://gu.qq.com/")
        guard let root = obj as? [String: Any],
              let data = root["data"] as? [String: Any],
              let node = data[code] as? [String: Any],
              let arr = node[p] as? [[Any]] else {
            throw DataError.empty("分钟K线 \(code) \(p)")
        }
        return arr.compactMap { row -> Candle? in
            guard row.count >= 6 else { return nil }
            let timeStr = "\(row[0])"
            guard let date = parseMinuteTime(timeStr) else { return nil }
            let o = num(row[1]), c = num(row[2]), h = num(row[3]), l = num(row[4]), v = num(row[5])
            guard o > 0, c > 0 else { return nil }
            return Candle(date: date, open: o, high: h, low: l, close: c, volume: v, amount: 0)
        }
    }

    private func dailyCandles(code: String, period: KPeriod, count: Int, useQFQ: Bool = true) async throws -> [Candle] {
        let p: String
        switch period {
        case .week: p = "week"
        case .month: p = "month"
        default: p = "day"
        }
        let qfq = useQFQ ? "qfq" : ""
        let url = "https://web.ifzq.gtimg.cn/appstock/app/fqkline/get?param=\(code),\(p),,,\(count),\(qfq)"
        let obj = try await HTTPClient.shared.json(from: url, referer: "https://gu.qq.com/")
        guard let root = obj as? [String: Any],
              let data = root["data"] as? [String: Any],
              let node = data[code] as? [String: Any] else {
            throw DataError.empty("K线 \(code) \(p)")
        }
        // 字段名可能是 qfqday / day / qfqweek / week ...
        let candidates = ["qfq\(p)", p]
        var arr: [[Any]]?
        for key in candidates {
            if let a = node[key] as? [[Any]], a.count > 2 { arr = a; break }
        }
        if arr == nil {
            for (k, v) in node {
                if k.contains(p), let a = v as? [[Any]], a.count > 2 { arr = a; break }
            }
        }
        guard let rows = arr else { throw DataError.empty("K线 \(code) \(p)") }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "Asia/Shanghai")
        df.dateFormat = "yyyy-MM-dd"

        return rows.compactMap { row -> Candle? in
            guard row.count >= 6 else { return nil }
            let ds = "\(row[0])"
            guard let date = df.date(from: ds) else { return nil }
            let o = num(row[1]), c = num(row[2]), h = num(row[3]), l = num(row[4]), v = num(row[5])
            guard o > 0, c > 0, h > 0, l > 0 else { return nil }
            return Candle(date: date, open: o, high: h, low: l, close: c, volume: v, amount: 0)
        }
    }

    private func parseMinuteTime(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyyMMddHHmm"
        return f.date(from: s)
    }

    private func num(_ v: Any) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) ?? 0 }
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }

    // MARK: 代码搜索

    func search(_ keyword: String) async throws -> [Security] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return [] }
        guard let encoded = kw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return [] }
        let url = "https://smartbox.gtimg.cn/s3/?q=\(encoded)&t=all"
        let data = try await HTTPClient.shared.data(from: url, referer: "https://gu.qq.com/")
        let text = HTTPClient.shared.string(from: data)
        guard let q1 = text.firstIndex(of: "\""), let q2 = text.lastIndex(of: "\""), q1 < q2 else { return [] }
        let payload = String(text[text.index(after: q1)..<q2])
        if payload == "N" { return [] }

        var result: [Security] = []
        for entry in payload.components(separatedBy: "^") {
            let parts = entry.components(separatedBy: "~")
            guard parts.count >= 5 else { continue }
            let marketTag = parts[0]
            let rawCode = parts[1]
            let name = parts[2]
            let type = parts[4]
            // 只保留股票与指数，过滤基金/债券
            guard type.hasPrefix("GP") || type.contains("ZS") || type.hasPrefix("ZS") else { continue }

            let market: Market
            var symbol = rawCode
            switch marketTag {
            case "sh": market = rawCode.hasPrefix("000") || rawCode.hasPrefix("999") ? .index : .sh
            case "sz": market = rawCode.hasPrefix("399") ? .index : .sz
            case "bj": market = .bj
            case "hk": market = .hk
            case "us": market = .us
            default: continue
            }
            if market == .us {
                // aapl.oq -> AAPL
                symbol = rawCode.components(separatedBy: ".").first?.uppercased() ?? rawCode.uppercased()
            } else if market == .index {
                symbol = rawCode
            }
            result.append(Security(symbol: symbol, name: name, market: market))
        }
        return result
    }
}

// MARK: - 代码工厂

enum SecurityFactory {
    static func fromTencentKey(_ key: String) -> Security {
        let lower = key.lowercased()
        if lower.hasPrefix("sh") {
            let code = String(key.dropFirst(2))
            let isIndex = code.hasPrefix("000") || code.hasPrefix("999")
            // 指数保留完整代码（sh000001），与初始自选股的 symbol 口径一致，
            // 否则 Security.id 会与实际存储的 id 不同导致 quotes 查不到
            return Security(symbol: isIndex ? "sh" + code : code, name: "", market: isIndex ? .index : .sh)
        }
        if lower.hasPrefix("sz") {
            let code = String(key.dropFirst(2))
            let isIndex = code.hasPrefix("399") || code == "980017"
            return Security(symbol: isIndex ? "sz" + code : code, name: "", market: isIndex ? .index : .sz)
        }
        if lower.hasPrefix("bj") {
            return Security(symbol: String(key.dropFirst(2)), name: "", market: .bj)
        }
        if lower.hasPrefix("hk") {
            return Security(symbol: String(key.dropFirst(2)), name: "", market: .hk)
        }
        if lower.hasPrefix("us") {
            return Security(symbol: String(key.dropFirst(2)).uppercased(), name: "", market: .us)
        }
        return Security(symbol: key, name: "", market: .sh)
    }

    /// 把用户输入的裸代码推测成 Security
    static func fromRawInput(_ input: String) -> Security? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.count == 6, s.allSatisfy(\.isNumber) {
            if s.hasPrefix("60") || s.hasPrefix("68") || s.hasPrefix("900") {
                return Security(symbol: s, name: "", market: .sh)
            }
            if s.hasPrefix("00") || s.hasPrefix("30") || s.hasPrefix("200") {
                if s.hasPrefix("000") && s != "000001" { return Security(symbol: s, name: "", market: .sz) }
                return Security(symbol: s, name: "", market: .sz)
            }
            if s.hasPrefix("8") || s.hasPrefix("4") || s.hasPrefix("92") {
                return Security(symbol: s, name: "", market: .bj)
            }
            return Security(symbol: s, name: "", market: .sz)
        }
        if s.count <= 5, s.allSatisfy(\.isNumber) {
            return Security(symbol: String(repeating: "0", count: max(0, 5 - s.count)) + s, name: "", market: .hk)
        }
        // 只把「纯 ASCII 字母 + 可选点号」当作美股代码。
        // 汉字也满足 isLetter，若不限制 ASCII，"五粮液" 会被误判成美股代码。
        let letters = s.uppercased()
        let isASCIIAlpha = letters.allSatisfy { ch in
            guard let a = ch.asciiValue else { return false }
            return (65...90).contains(a) || (97...122).contains(a) || a == 46 /* . */ || a == 45 /* - */
        }
        if isASCIIAlpha, !letters.isEmpty {
            return Security(symbol: letters, name: "", market: .us)
        }
        return nil
    }
}

// MARK: - 数组分块

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
