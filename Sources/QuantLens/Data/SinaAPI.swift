import Foundation

// MARK: - 新浪资金流（主数据源：主力/超大单/大单 净额，含历史序列）

/// 新浪财经资金流接口，无需 token。
/// r0 = 超大单（机构席位），r1 = 大单，r2 = 中单，r3 = 小单。
/// 「主力净额」= r0 净额 + r1 净额，与东财口径接近。
actor SinaAPI {

    static let shared = SinaAPI()

    private let referer = "https://finance.sina.com.cn"

    /// 今日资金流分布
    func fundFlowToday(security: Security) async throws -> FundFlow? {
        guard security.market == .sh || security.market == .sz || security.market == .bj else { return nil }
        let code = security.tencentCode
        let url = "https://vip.stock.finance.sina.com.cn/quotes_service/api/json_v2.php/MoneyFlow.ssi_ssfx_flzjtj?daima=\(code)"
        let obj = try await HTTPClient.shared.json(from: url, referer: referer)
        guard let dict = obj as? [String: Any] else { return nil }

        let r0in = d(dict["r0_in"]), r0out = d(dict["r0_out"])
        let r1in = d(dict["r1_in"]), r1out = d(dict["r1_out"])
        let r2in = d(dict["r2_in"]), r2out = d(dict["r2_out"])
        let r3in = d(dict["r3_in"]), r3out = d(dict["r3_out"])

        let superLarge = r0in - r0out
        let large = r1in - r1out
        let medium = r2in - r2out
        let small = r3in - r3out
        let main = superLarge + large
        let total = main + medium + small
        let mainRatio = total != 0 ? main / max(abs(r0in + r0out + r1in + r1out + r2in + r2out + r3in + r3out), 1) * 100 * 2 : 0

        return FundFlow(
            mainNet: main,
            superLargeNet: superLarge,
            largeNet: large,
            mediumNet: medium,
            smallNet: small,
            mainRatio: mainRatio,
            date: Date()
        )
    }

    /// 历史每日主力净额（按日期升序）
    func fundFlowHistory(security: Security, days: Int = 60) async throws -> [FundFlow] {
        guard security.market == .sh || security.market == .sz || security.market == .bj else { return [] }
        let code = security.tencentCode
        let url = "https://vip.stock.finance.sina.com.cn/quotes_service/api/json_v2.php/MoneyFlow.ssl_qsfx_zjlrqs?page=1&num=\(days)&sort=opendate&asc=0&daima=\(code)"
        let obj = try await HTTPClient.shared.json(from: url, referer: referer)
        guard let arr = obj as? [[String: Any]] else { return [] }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "Asia/Shanghai")
        df.dateFormat = "yyyy-MM-dd"

        var flows: [FundFlow] = []
        for item in arr {
            let dateStr = (item["opendate"] as? String) ?? ""
            guard let date = df.date(from: dateStr) else { continue }
            let r0 = d(item["r0_net"])
            let net = d(item["netamount"])
            let ratio = d(item["r0_ratio"]) * 100
            flows.append(FundFlow(
                mainNet: r0,
                superLargeNet: r0,
                largeNet: net - r0,
                mediumNet: 0,
                smallNet: 0,
                mainRatio: ratio,
                date: date
            ))
        }
        return flows.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    private func d(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let s = v as? String { return Double(s) ?? 0 }
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }
}

// MARK: - 行情聚合服务

actor MarketService {

    static let shared = MarketService()

    /// 并发拉取一只股票的完整数据
    func load(security: Security, period: KPeriod) async -> StockData {
        async let quoteTask: Quote? = {
            do { return try await TencentAPI.shared.quotes(codes: [security.tencentCode])[security.tencentCode] }
            catch { return nil }
        }()

        async let candlesTask: [Candle] = {
            do { return try await TencentAPI.shared.candles(for: security, period: period) }
            catch { return [] }
        }()

        async let flowTask: FundFlow? = {
            do { return try await SinaAPI.shared.fundFlowToday(security: security) }
            catch { return nil }
        }()

        async let flowHistTask: [FundFlow] = {
            do { return try await SinaAPI.shared.fundFlowHistory(security: security, days: 60) }
            catch { return [] }
        }()

        let (q, c, f, fh) = await (quoteTask, candlesTask, flowTask, flowHistTask)

        var sec = security
        if sec.name.isEmpty, let name = q?.security.name, !name.isEmpty {
            sec = Security(symbol: security.symbol, name: name, market: security.market)
        }
        var quote = q
        if var qq = quote {
            qq.security = sec
            quote = qq
        }

        return StockData(
            security: sec,
            quote: quote,
            candles: c,
            fundFlow: f,
            fundFlowHistory: fh
        )
    }

    /// 批量刷新自选列表的快照
    func refreshQuotes(securities: [Security]) async -> [String: Quote] {
        let codes = securities.map(\.tencentCode)
        do {
            var map = try await TencentAPI.shared.quotes(codes: codes)
            // 补全显示名
            for sec in securities {
                if let q = map[sec.id], q.security.name.isEmpty {
                    var nq = q
                    nq.security = Security(symbol: sec.symbol, name: sec.name, market: sec.market)
                    map[sec.id] = nq
                }
            }
            return map
        } catch {
            return [:]
        }
    }
}
