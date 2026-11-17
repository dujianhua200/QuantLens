import Foundation

// MARK: - 新浪 K线补充（美股 / 北交所 / 港股历史）

/// 腾讯接口在以下场景覆盖不足，用新浪补齐：
/// - 美股：腾讯只返回首末两根（数据源限制），新浪返回完整历史
/// - 北交所：腾讯只有当日，新浪有日线序列
/// - 港股：腾讯必须去掉 qfq 参数才能拿到长历史
actor SinaKlineAPI {

    static let shared = SinaKlineAPI()

    private let referer = "https://finance.sina.com.cn"

    /// 美股日线（新浪 US_MinKService，JSONP 包装）
    func usDaily(symbol: String, limit: Int = 400) async throws -> [Candle] {
        let sym = symbol.uppercased()
        let url = "https://stock.finance.sina.com.cn/usstock/api/jsonp_v2.php/x/US_MinKService.getDailyK?symbol=\(sym)&___qn=3"
        let data = try await HTTPClient.shared.data(from: url, referer: referer)
        let text = HTTPClient.shared.string(from: data)

        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]") else {
            throw DataError.decode("美股K线格式异常")
        }
        let jsonText = String(text[start...end])
        guard let jsonData = jsonText.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
            throw DataError.decode("美股K线解析失败")
        }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "America/New_York")

        var candles: [Candle] = []
        for item in arr {
            guard let ds = item["d"] as? String, let date = df.date(from: ds) else { continue }
            let o = d(item["o"]), h = d(item["h"]), l = d(item["l"]), c = d(item["c"])
            let v = d(item["v"]), a = d(item["a"])
            guard o > 0, c > 0 else { continue }
            candles.append(Candle(date: date, open: o, high: h, low: l, close: c,
                                  volume: v, amount: a))
        }
        candles.sort { $0.date < $1.date }
        return Array(candles.suffix(limit))
    }

    /// A股 / 北交所日线（新浪 CN_MarketDataService）
    func cnDaily(code: String, limit: Int = 400) async throws -> [Candle] {
        let url = "https://quotes.sina.cn/cn/api/json_v2.php/CN_MarketDataService.getKLineData?symbol=\(code)&scale=240&ma=no&datalen=\(limit)"
        let obj = try await HTTPClient.shared.json(from: url, referer: referer)
        guard let arr = obj as? [[String: Any]] else {
            throw DataError.empty("新浪日线 \(code)")
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "Asia/Shanghai")

        var candles: [Candle] = []
        for item in arr {
            guard let ds = item["day"] as? String, let date = df.date(from: ds) else { continue }
            let o = d(item["open"]), h = d(item["high"]), l = d(item["low"]), c = d(item["close"])
            let v = d(item["volume"])
            guard o > 0, c > 0 else { continue }
            // 新浪 A股 volume 单位是股，转成手
            candles.append(Candle(date: date, open: o, high: h, low: l, close: c,
                                  volume: v / 100, amount: 0))
        }
        candles.sort { $0.date < $1.date }
        return candles
    }

    private func d(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let s = v as? String { return Double(s) ?? 0 }
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }
}
