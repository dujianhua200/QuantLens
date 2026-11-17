import Foundation

// MARK: - 盘中数据服务（分时 / 五档 / 逐笔）

/// 腾讯的盘中接口封装。
///
/// 三个接口解决的问题：
/// - `minute/query`：分时图（每分钟一个点，含均价）
/// - `qt.gtimg.cn`：五档盘口 + 内外盘（已在实时行情里）
/// - `detail/data`：逐笔成交明细（分页，每页 70 笔）
/// 逐笔末页号缓存（线程安全）。页号一天内单调，缓存后刷新不再反复二分探测。
final class LastPageCache {
    static let shared = LastPageCache()
    private let lock = NSLock()
    private var pages: [String: Int] = [:]
    func get(_ code: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return pages[code]
    }
    func set(_ code: String, _ page: Int) {
        lock.lock(); defer { lock.unlock() }
        pages[code] = page
    }
}

actor IntradayService {

    static let shared = IntradayService()

    private let detailPageSize = 70

    // MARK: - 分时图

    /// 拉取当日分时。
    ///
    /// 腾讯返回格式：`"0930 1426.30 189 26957070.00"`
    /// 依次是 时间 / 价格 / 累计成交量(手) / 累计成交额(元)。
    /// 均价 = 累计成交额 / (累计成交量 × 100)。
    nonisolated func intraday(security: Security) async throws -> IntradayData {
        let code = security.tencentCode
        let url = "https://web.ifzq.gtimg.cn/appstock/app/minute/query?code=\(code)"
        let obj = try await HTTPClient.shared.json(from: url, referer: "https://gu.qq.com/")

        guard let root = obj as? [String: Any],
              let data = root["data"] as? [String: Any],
              let node = data[code] as? [String: Any] else {
            throw DataError.empty("分时 \(code)")
        }

        // data.data.data 是字符串数组
        var rows: [String] = []
        if let inner = node["data"] as? [String: Any], let arr = inner["data"] as? [String] {
            rows = arr
        } else if let arr = node["data"] as? [String] {
            rows = arr
        }

        // 昨收：优先从 qt 字段取
        var prevClose = 0.0
        if let qt = node["qt"] as? [String: Any],
           let arr = qt[code] as? [Any], arr.count > 4 {
            prevClose = Self.num(arr[4])
        }
        if prevClose <= 0, let first = rows.first {
            // 退化：用第一个点的价格
            let parts = first.split(separator: " ")
            if parts.count > 1 { prevClose = Double(parts[1]) ?? 0 }
        }

        var points: [IntradayPoint] = []
        let cal = Calendar.current
        let now = Date()
        let dayStart = cal.startOfDay(for: now)

        for row in rows {
            let parts = row.split(separator: " ")
            guard parts.count >= 3 else { continue }
            let timeStr = String(parts[0])       // "0930"
            let price = Double(parts[1]) ?? 0
            let cumVol = Double(parts[2]) ?? 0
            let cumAmt = parts.count > 3 ? (Double(parts[3]) ?? 0) : 0
            guard price > 0, timeStr.count == 4 else { continue }

            let hh = Int(timeStr.prefix(2)) ?? 0
            let mm = Int(timeStr.suffix(2)) ?? 0
            guard let time = cal.date(bySettingHour: hh, minute: mm, second: 0, of: dayStart) else { continue }

            // 均价 = 累计成交额 / 累计成交量（股）
            let avg = cumVol > 0 ? cumAmt / (cumVol * 100) : price

            points.append(IntradayPoint(
                time: time,
                price: price,
                avgPrice: avg,
                volume: 0,
                cumVolume: cumVol,
                cumAmount: cumAmt
            ))
        }

        // 逐分钟量 = 相邻累计差
        for i in points.indices.reversed() where i > 0 {
            points[i].volume = max(0, points[i].cumVolume - points[i - 1].cumVolume)
        }
        if !points.isEmpty {
            points[0].volume = points[0].cumVolume
        }

        let highs = points.map(\.price)
        return IntradayData(
            security: security,
            previousClose: prevClose,
            points: points,
            dayHigh: highs.max() ?? 0,
            dayLow: highs.min() ?? 0,
            updatedAt: Date()
        )
    }

    // MARK: - 五档盘口

    /// 从实时行情拉五档。腾讯行情字段：
    /// 9/10 买1价/量，11/12 买2，……，19/20 卖1价/量，……
    nonisolated func orderBook(security: Security) async throws -> OrderBook {
        let code = security.tencentCode
        let url = "https://qt.gtimg.cn/q=\(code)"
        let data = try await HTTPClient.shared.data(from: url, referer: "https://gu.qq.com/")
        let text = HTTPClient.shared.string(from: data)

        guard let eq = text.firstIndex(of: "="),
              let q1 = text.firstIndex(of: "\""),
              let q2 = text.lastIndex(of: "\""), q1 < q2 else {
            throw DataError.decode("盘口格式异常")
        }
        _ = eq
        let f = String(text[text.index(after: q1)..<q2]).components(separatedBy: "~")
        guard f.count > 30 else { throw DataError.decode("盘口字段不足") }

        var bids: [OrderBookLevel] = []
        var asks: [OrderBookLevel] = []
        for i in 0..<5 {
            let bp = Self.num(f, 9 + i * 2)
            let bv = Self.num(f, 10 + i * 2)
            bids.append(OrderBookLevel(level: i + 1, price: bp, volume: bv))

            let ap = Self.num(f, 19 + i * 2)
            let av = Self.num(f, 20 + i * 2)
            asks.append(OrderBookLevel(level: i + 1, price: ap, volume: av))
        }

        let outer = Self.num(f, 7)
        let inner = Self.num(f, 8)

        var ts = Date()
        if f.count > 30, f[30].count >= 14 {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(identifier: "Asia/Shanghai")
            for fmt in ["yyyyMMddHHmmss", "yyyyMMddHHmm"] {
                df.dateFormat = fmt
                if let d = df.date(from: f[30]) { ts = d; break }
            }
        }

        return OrderBook(bids: bids, asks: asks,
                         outerVolume: outer, innerVolume: inner, timestamp: ts)
    }

    // MARK: - 逐笔成交

    /// 拉逐笔成交。
    ///
    /// 页序：p=0 是当日最早的一页（09:25 起），页号越大时间越晚。
    /// 要取"最近的成交"，需要先探测总页数，再从末尾往前取。
    /// - Parameter pages: 需要多少页（每页约 70 笔）
    /// - Parameter latest: true 表示取最新的若干页，false 表示从头取
    nonisolated func trades(security: Security, pages: Int = 2, latest: Bool = true) async throws -> [Trade] {
        guard security.market == .sh || security.market == .sz || security.market == .bj else {
            return []   // 港美股无此接口
        }
        let code = security.tencentCode
        var all: [Trade] = []

        let startPage: Int
        if latest {
            // 用第 0 页的返回值探测总页数（格式里第一个数字其实是当前页号，不是总数）
            // 实测总页数不可靠，改为二分探测：找到第一个空页
            startPage = await probeLastPage(code: code, hint: pages)
        } else {
            startPage = 0
        }

        let firstPage = max(0, startPage - max(1, pages) + 1)
        for page in firstPage...max(firstPage, startPage) {
            let url = "https://stock.gtimg.cn/data/index.php?appn=detail&action=data&c=\(code)&p=\(page)"
            guard let data = try? await HTTPClient.shared.data(from: url, referer: "https://gu.qq.com/") else {
                continue
            }
            let text = HTTPClient.shared.string(from: data)
            all.append(contentsOf: Self.parseTradePage(text, day: Date()))
            if page < startPage {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        // 按序号去重 + 升序
        var seen = Set<Int>()
        var unique: [Trade] = []
        for t in all where !seen.contains(t.sequence) {
            seen.insert(t.sequence)
            unique.append(t)
        }
        return unique.sorted { $0.sequence < $1.sequence }
    }

    /// 探测最后一个有数据的页号。
    /// 从 `hint` 开始每次翻倍试探，找到空页后二分收敛。
    /// 探测末页号。优先使用缓存：命中且有效则直接返回（最多回退/前进少量页），否则二分探测。
    nonisolated func probeLastPage(code: String, hint: Int) async -> Int {
        func hasData(_ p: Int) async -> Bool {
            guard p >= 0 else { return false }
            let url = "https://stock.gtimg.cn/data/index.php?appn=detail&action=data&c=\(code)&p=\(p)"
            guard let data = try? await HTTPClient.shared.data(from: url, referer: "https://gu.qq.com/") else {
                return false
            }
            let text = HTTPClient.shared.string(from: data)
            return text.contains("/") && text.contains("|")
        }

        if let c = LastPageCache.shared.get(code) {
            // 缓存命中：以缓存页为起点，向后最多试探 5 页（盘口只增不减），向前回退找边界
            var last = c
            var probe = c + 1
            var advanced = 0
            while advanced < 5 {
                if await hasData(probe) { last = probe; probe += 1; advanced += 1 }
                else { break }
            }
            // 缓存页本身已空（回滚/数据变动）：向前回退找最后一个非空页
            while last > 0 {
                if await hasData(last) { break }
                last -= 1
            }
            LastPageCache.shared.set(code, last)
            return last
        }

        // 无缓存：二分探测
        var lo = 0
        var hi = max(4, hint)
        var attempts = 0
        while attempts < 8 {
            if await hasData(hi) {
                lo = hi
                hi *= 2
                attempts += 1
                try? await Task.sleep(nanoseconds: 50_000_000)
            } else {
                break
            }
        }
        var high = hi
        while high - lo > 1 && attempts < 16 {
            let mid = (lo + high) / 2
            if await hasData(mid) { lo = mid } else { high = mid }
            attempts += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        LastPageCache.shared.set(code, lo)
        return lo
    }

    /// 解析一页：`v_detail_data_sh600519=[0,"0/09:25:02/1426.30/0.30/189/26957070/B|..."]`
    private static func parseTradePage(_ text: String, day: Date) -> [Trade] {
        guard let lb = text.firstIndex(of: "["),
              let rb = text.lastIndex(of: "]"), lb < rb else { return [] }
        let payload = String(text[text.index(after: lb)..<rb])

        // 提取引号内的内容
        guard let q1 = payload.firstIndex(of: "\""),
              let q2 = payload.lastIndex(of: "\""), q1 < q2 else { return [] }
        let body = String(payload[payload.index(after: q1)..<q2])
        if body.isEmpty { return [] }

        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "Asia/Shanghai")
        df.dateFormat = "HH:mm:ss"

        var out: [Trade] = []
        for row in body.components(separatedBy: "|") {
            let p = row.components(separatedBy: "/")
            guard p.count >= 7 else { continue }
            guard let seq = Int(p[0]),
                  let price = Double(p[2]),
                  let change = Double(p[3]),
                  let vol = Double(p[4]),
                  let amt = Double(p[5]) else { continue }

            let timeStr = p[1]
            let time = df.date(from: timeStr).map { t -> Date in
                let c = cal.dateComponents([.hour, .minute, .second], from: t)
                return cal.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0,
                                second: c.second ?? 0, of: dayStart) ?? dayStart
            } ?? dayStart

            let side = TradeSide(rawValue: p[6]) ?? .neutral
            out.append(Trade(sequence: seq, time: time, price: price, change: change,
                             volume: vol, amount: amt, side: side))
        }
        return out
    }

    // MARK: - 工具

    private static func num(_ f: [String], _ i: Int) -> Double {
        guard i < f.count else { return 0 }
        return Double(f[i]) ?? 0
    }

    private static func num(_ v: Any) -> Double {
        if let d = v as? Double { return d }
        if let s = v as? String { return Double(s) ?? 0 }
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }
}
