import Foundation

// MARK: - 集合竞价选股引擎

/// 在 09:15–09:25 采集候选股的竞价盘口，评分选出「开盘上涨概率大」的标的。
///
/// 核心逻辑（基于 A 股集合竞价规则）：
/// 1. **09:20 前可撤单** → 虚假挂单集中在此，只采样不下结论；
/// 2. **09:20 后不可撤单** → 委托真实，高开幅度与量能是最可信信号；
/// 3. **9:25 撮合开盘** → 用锁定期的稳定性 + 缺口幅度 + 竞价量能打分。
///
/// 关键指标：
/// - 高开幅度：2%~7% 最优（过低没资金，过高易炸板）；
/// - 竞价量比 / 竞价额：反映资金关注度；
/// - 稳定性：9:20 锁定后缺口维持或走高 = 真实买盘；大幅回落 = 撤单假象，剔除。
actor AuctionScanner {

    static let shared = AuctionScanner()

    // MARK: 配置

    /// 候选池上限
    private let candidateLimit = 420
    /// 每批请求的代码数（腾讯批量接口实测 599 只 0.5s）
    private let batchSize = 300
    /// 采样间隔（秒）
    private let sampleInterval: TimeInterval = 3.0

    // MARK: 状态

    /// code -> 采样序列
    private var samples: [String: [AuctionSample]] = [:]
    /// code -> 基础信息
    private var meta: [String: AuctionMeta] = [:]
    /// 候选代码（腾讯格式 sh600519）
    private var candidates: [String] = []
    private var lastPoolRefresh: Date?
    private var lastAmount: [String: Double] = [:]
    /// 东财请求连续失败次数（用于退避）
    private var poolFailures = 0
    /// 上次东财请求时刻（失败后强制冷却）
    private var lastPoolAttempt: Date?

    private struct AuctionMeta {
        var security: Security
        var name: String
        var prevClose: Double
        var floatCap: Double
        var industry: String
        /// 昨日成交量（手），用于估算竞价量比
        var prevVolume: Double
        var prevAmount: Double
    }

    // MARK: - 阶段判定

    nonisolated static func phase(at date: Date = Date()) -> AuctionPhase {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let comp = cal.dateComponents([.hour, .minute, .weekday], from: date)
        guard let h = comp.hour, let m = comp.minute else { return .idle }
        // 周末不交易
        if let wd = comp.weekday, wd == 1 || wd == 7 { return .closed }
        let t = h * 60 + m
        switch t {
        case ..<(9 * 60 + 15): return .idle
        case (9 * 60 + 15)..<(9 * 60 + 20): return .earlyNoisy
        case (9 * 60 + 20)..<(9 * 60 + 25): return .locked
        case (9 * 60 + 25)..<(9 * 60 + 30): return .settled
        case (9 * 60 + 30)..<(15 * 60 + 5): return .settled
        default: return .closed
        }
    }

    /// 是否处于需要密集采样的窗口
    nonisolated static func shouldSample(at date: Date = Date()) -> Bool {
        let p = phase(at: date)
        return p == .earlyNoisy || p == .locked
    }

    // MARK: - 候选池

    /// 构建候选池。三级数据源降级，保证任何情况下都有候选：
    /// ① 新浪排行（稳定不限流，主选）
    /// ② 东财排行（备用）
    /// ③ 内置活跃股池（兜底）
    ///
    /// 取「涨幅 / 量 / 成交额 / 换手」四维前列，覆盖资金关注度高的标的。
    private func refreshPoolIfNeeded(force: Bool = false) async {
        // 池子 30 分钟内复用
        if !force, let t = lastPoolRefresh, Date().timeIntervalSince(t) < 1800, !candidates.isEmpty {
            return
        }
        // 失败退避：60s 内不重复打同一个源
        if let a = lastPoolAttempt, poolFailures > 0, Date().timeIntervalSince(a) < 60, !candidates.isEmpty {
            return
        }
        lastPoolAttempt = Date()

        var picked: [String: AuctionMeta] = [:]

        // ① 新浪排行（四维）
        for sort in ["changepercent", "amount", "turnoverratio", "volume"] {
            for page in 1...2 {
                let url = "https://vip.stock.finance.sina.com.cn/quotes_service/api/json_v2.php/"
                    + "Market_Center.getHQNodeData?page=\(page)&num=100&sort=\(sort)&asc=0&node=hs_a"
                guard let data = try? await HTTPClient.shared.data(from: url, referer: "https://finance.sina.com.cn"),
                      let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    poolFailures += 1
                    break
                }
                poolFailures = 0
                for row in rows {
                    guard let code = row["code"] as? String, code.count == 6 else { continue }
                    let name = (row["name"] as? String) ?? ""
                    if name.contains("ST") || name.contains("退") { continue }
                    let prev = num(row["settlement"])
                    guard prev > 0 else { continue }
                    let nmc = num(row["nmc"]) / 1e4   // 万元 -> 亿元
                    guard nmc >= 8, nmc <= 800 else { continue }
                    let security = Self.makeSecurity(code: code, name: name)
                    let key = security.tencentCode
                    if picked[key] != nil { continue }
                    picked[key] = AuctionMeta(
                        security: security,
                        name: name,
                        prevClose: prev,
                        floatCap: nmc,
                        industry: "—",
                        prevVolume: num(row["volume"]) / 100,   // 股 -> 手
                        prevAmount: num(row["amount"])
                    )
                }
                try? await Task.sleep(nanoseconds: 220_000_000)
            }
        }

        // ② 东财补齐（新浪不足时才用）
        if picked.count < 120 {
            let fields = "f12,f14,f2,f3,f5,f6,f8,f10,f17,f18,f20,f21,f100"
            for board in ["fid=f10", "fid=f3"] {
                for pn in 1...2 {
                    let url = "https://push2.eastmoney.com/api/qt/clist/get?po=1&np=1&fltt=2&invt=2&\(board)"
                        + "&fs=m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23&fields=\(fields)&pn=\(pn)&pz=100"
                    guard let data = try? await HTTPClient.shared.data(from: url, referer: "https://quote.eastmoney.com/") else {
                        poolFailures += 1
                        continue
                    }
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let d = json["data"] as? [String: Any],
                          let diff = d["diff"] as? [[String: Any]] else { continue }
                    poolFailures = 0
                    for row in diff {
                        guard let code = row["f12"] as? String, code.count == 6 else { continue }
                        let name = (row["f14"] as? String) ?? ""
                        if name.contains("ST") || name.contains("退") { continue }
                        let prev = num(row["f18"])
                        guard prev > 0 else { continue }
                        let cap = num(row["f21"]) / 1e8
                        guard cap >= 8, cap <= 800 else { continue }
                        let security = Self.makeSecurity(code: code, name: name)
                        let key = security.tencentCode
                        if picked[key] != nil { continue }
                        picked[key] = AuctionMeta(
                            security: security,
                            name: name,
                            prevClose: prev,
                            floatCap: cap,
                            industry: (row["f100"] as? String) ?? "—",
                            prevVolume: num(row["f5"]),
                            prevAmount: num(row["f6"])
                        )
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }

        guard !picked.isEmpty else {
            await useFallbackPool()
            return
        }

        // 按成交额优先截断（资金关注度最高的进池）
        let sorted = picked.sorted { $0.value.prevAmount > $1.value.prevAmount }
        let limited = Array(sorted.prefix(candidateLimit))

        candidates = limited.map(\.key)
        meta = Dictionary(uniqueKeysWithValues: limited.map { ($0.key, $0.value) })
        lastPoolRefresh = Date()
    }

    /// 东财不可用时的兜底候选池：沪深高流动性主流标的。
    /// 保证竞价监控在任何行情源故障下都能跑起来。
    private func useFallbackPool() async {
        guard candidates.isEmpty || meta.isEmpty else { return }
        var picked: [String: AuctionMeta] = [:]
        let fallback: [(String, String)] = [
            ("600519", "贵州茅台"), ("000001", "平安银行"), ("300750", "宁德时代"),
            ("601318", "中国平安"), ("002594", "比亚迪"), ("688981", "中芯国际"),
            ("600036", "招商银行"), ("000858", "五粮液"), ("601899", "紫金矿业"),
            ("002415", "海康威视"), ("600030", "中信证券"), ("000651", "格力电器"),
            ("600887", "伊利股份"), ("000333", "美的集团"), ("601166", "兴业银行"),
            ("300059", "东方财富"), ("600900", "长江电力"), ("601012", "隆基绿能"),
            ("000725", "京东方A"), ("600276", "恒瑞医药"), ("002230", "科大讯飞"),
            ("600809", "山西汾酒"), ("000568", "泸州老窖"), ("603288", "海天味业"),
            ("002714", "牧原股份"), ("601888", "中国中免"), ("002475", "立讯精密"),
            ("600585", "海螺水泥"), ("000063", "中兴通讯"), ("601088", "中国神华"),
            ("601398", "工商银行"), ("601857", "中国石油"), ("600028", "中国石化"),
            ("601288", "农业银行"), ("600000", "浦发银行"), ("601988", "中国银行"),
            ("002304", "洋河股份"), ("600031", "三一重工"), ("601668", "中国建筑"),
            ("000002", "万科A"), ("600048", "保利发展"), ("601601", "中国太保"),
            ("601628", "中国人寿"), ("600016", "民生银行"), ("601169", "北京银行"),
            ("002027", "分众传媒"), ("300760", "迈瑞医疗"), ("688111", "金山办公"),
            ("603259", "药明康德"), ("300124", "汇川技术"), ("002352", "顺丰控股"),
            ("600104", "上汽集团"), ("601633", "长城汽车"), ("000538", "云南白药"),
            ("600690", "海尔智家"), ("002050", "三花智控"), ("300274", "阳光电源"),
            ("601127", "赛力斯"), ("002460", "赣锋锂业"), ("600438", "通威股份"),
            ("601138", "工业富联"), ("000977", "浪潮信息"), ("002049", "紫光国微"),
            ("603501", "韦尔股份"), ("688036", "传音控股"), ("300308", "中际旭创"),
            ("002371", "北方华创"), ("688012", "中微公司"), ("603986", "兆易创新"),
            ("600745", "闻泰科技"), ("000100", "TCL科技"), ("002241", "歌尔股份"),
            ("300496", "中科创达"), ("688169", "石头科技"), ("603195", "公牛集团"),
            ("002705", "新宝股份"), ("688696", "极米科技"), ("002343", "慈文传媒")
        ]
        for (code, name) in fallback {
            let sec = Self.makeSecurity(code: code, name: name)
            let key = sec.tencentCode
            if picked[key] != nil { continue }
            picked[key] = AuctionMeta(
                security: sec,
                name: name,
                prevClose: 0,       // 采样时用实时盘口填充
                floatCap: 200,
                industry: "—",
                prevVolume: 0,
                prevAmount: 0
            )
        }
        candidates = picked.keys.sorted()
        meta = picked
        lastPoolRefresh = Date()
    }

    nonisolated static func makeSecurity(code: String, name: String) -> Security {
        let market: Market
        if code.hasPrefix("6") { market = .sh }
        else if code.hasPrefix("0") || code.hasPrefix("3") { market = .sz }
        else if code.hasPrefix("8") || code.hasPrefix("4") { market = .bj }
        else { market = .sh }
        return Security(symbol: code, name: name, market: market)
    }

    // MARK: - 采样

    /// 执行一轮采样，返回本轮原始报价数量
    @discardableResult
    func sampleOnce(forcePool: Bool = false) async -> Int {
        await refreshPoolIfNeeded(force: forcePool)
        guard !candidates.isEmpty else { return 0 }

        var total = 0
        var idx = 0
        while idx < candidates.count {
            let end = min(idx + batchSize, candidates.count)
            let batch = Array(candidates[idx..<end])
            let url = "https://qt.gtimg.cn/q=" + batch.joined(separator: ",")
            guard let data = try? await HTTPClient.shared.batchData(from: url) else {
                idx = end
                continue
            }
            let text = HTTPClient.shared.string(from: data)
            for line in text.split(separator: ";") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let body = String(line[line.index(after: eq)...])
                let payload = body.trimmingCharacters(in: CharacterSet(charactersIn: "\"\n\r "))
                let f = payload.components(separatedBy: "~")
                guard f.count > 45 else { continue }
                let rawCode = f[2]
                var market = "sh"
                if rawCode.hasPrefix("0") || rawCode.hasPrefix("3") { market = "sz" }
                else if rawCode.hasPrefix("8") || rawCode.hasPrefix("4") { market = "bj" }
                let key = market + rawCode
                guard var m = meta[key] else { continue }

                let matchPrice = num2(f[3])     // 竞价虚拟撮合价
                let prevClose = num2(f[4])
                let volume = num2(f[6])         // 竞价累计量（手）
                if prevClose > 0 { m.prevClose = prevClose }
                // 兜底池没有流通市值时，用盘口字段补（f[44] 单位：亿）
                if m.floatCap <= 0 || m.floatCap == 200, f.count > 44 {
                    let cap = num2(f[44])
                    if cap > 0 { m.floatCap = cap }
                }

                // 竞价额：字段 37 为成交额（万元）
                var amount = f.count > 37 ? num2(f[37]) * 1e4 : 0
                if amount == 0, f.count > 35 {
                    let parts = f[35].components(separatedBy: "/")
                    if parts.count >= 3 { amount = num2(parts[2]) }
                }
                guard matchPrice > 0, prevClose > 0 else { continue }

                let gap = (matchPrice - prevClose) / prevClose * 100
                let prevAmt = lastAmount[key] ?? 0
                let delta = max(0, volume - prevAmt)

                let s = AuctionSample(
                    at: Date(),
                    matchPrice: matchPrice,
                    gapPct: gap,
                    volume: volume,
                    amount: amount,
                    volumeDelta: delta
                )
                samples[key, default: []].append(s)
                lastAmount[key] = volume
                meta[key] = m
                total += 1
            }
            idx = end
        }
        return total
    }

    // MARK: - 评分

    /// 生成选股结果。以 9:20 锁定后的采样为准。
    func evaluate() -> [AuctionPick] {
        var picks: [AuctionPick] = []

        for (key, list) in samples {
            guard let m = meta[key], !list.isEmpty else { continue }
            guard let latest = list.last else { continue }

            // 昨收与最新缺口
            let prevClose = m.prevClose
            guard prevClose > 0 else { continue }
            let gap = latest.gapPct

            // 过滤：必须高开（低开/平开不是「开盘上涨」目标）
            guard gap >= 0.5 else { continue }

            // 锁定期采样（09:20 后）
            let lockedSamples = list.filter {
                let comp = Calendar(identifier: .gregorian)
                    .dateComponents([.hour, .minute], from: $0.at)
                guard let h = comp.hour, let mi = comp.minute else { return false }
                let t = h * 60 + mi
                return t >= 9 * 60 + 20 && t <= 9 * 60 + 25
            }

            // 稳定性：锁定后缺口是否维持
            var stability = 0.7
            var gapAtLock = gap
            if let first = lockedSamples.first {
                gapAtLock = first.gapPct
                let decay = first.gapPct > 0 ? (latest.gapPct - first.gapPct) / first.gapPct : 0
                // 走高 +1，持平 0.7，回落扣分
                if decay >= 0.05 { stability = 1.0 }
                else if decay >= -0.05 { stability = 0.85 }
                else if decay >= -0.2 { stability = 0.6 }
                else if decay >= -0.4 { stability = 0.35 }
                else { stability = 0.1 }
            } else if list.count >= 2 {
                // 无锁定期采样：用全程斜率近似
                let firstGap = list[0].gapPct
                let decay = firstGap > 0 ? (latest.gapPct - firstGap) / firstGap : 0
                stability = decay >= -0.1 ? 0.75 : (decay >= -0.35 ? 0.5 : 0.2)
            } else {
                // 只有一个采样点：无法判断稳定性，取中性
                stability = 0.6
            }

            // 竞价量比：竞价累计量 ÷ 昨日每分钟均量。
            // 注意：m.prevVolume 必须是「昨日全天量」，而 latest.volume 是「竞价累计量」。
            // 若当前已过 09:30，latest.volume 会变成全天累计量，此时量比失去意义，
            // 用 1 作为分钟数基准可识别这种失真（比值会远大于 30），直接置 0 交由换手口径处理。
            let prevMinuteVol = m.prevVolume > 0 ? m.prevVolume / 240.0 : 0
            var volRatio = prevMinuteVol > 0 ? latest.volume / prevMinuteVol : 0
            // 竞价量不可能超过昨日全天量；超过说明口径错位，弃用
            if volRatio > 30 { volRatio = 0 }

            // 竞价换手率 %：竞价量(手) × 100股 ÷ 流通股本 × 100%
            // 流通股本 = 流通市值(亿) × 1e8 ÷ 价格
            let turnover: Double
            if m.floatCap > 0 {
                let floatShares = m.floatCap * 1e8 / max(latest.matchPrice, 0.01)
                turnover = floatShares > 0 ? latest.volume * 100 / floatShares * 100 : 0
            } else {
                turnover = 0
            }

            // ===== 打分（0-100，连续函数，满分需三要素同时突出）=====
            var score = 12.0
            var reasons: [String] = []
            var risks: [String] = []

            // ① 缺口强度（0-22）：以 3% 为峰值，向两侧平滑衰减
            //    3% 最理想（有资金但不透支），1% 和 8% 都减半
            let gapIdeal = 3.0
            let gapDist = abs(gap - gapIdeal)
            var gapScore = 22.0 * exp(-pow(gapDist / 4.2, 2))
            if gap < 0.5 { gapScore = 0 }
            score += gapScore

            if gap >= 2.0 && gap <= 5.0 {
                reasons.append(String(format: "高开 %.2f%%，处于最佳延续区间", gap))
            } else if gap > 5 && gap < 8 {
                reasons.append(String(format: "高开 %.2f%%，偏强", gap))
                risks.append("高开幅度较大，留意开盘冲高回落")
            } else if gap >= 8 {
                risks.append(String(format: "高开 %.2f%%，追高风险显著", gap))
            } else if gap >= 0.5 {
                reasons.append(String(format: "微幅高开 %.2f%%", gap))
            }

            // ② 稳定性（0-24）：锁定期缺口维持程度，真假分水岭
            score += stability * 24
            if stability >= 0.95 {
                reasons.append("9:20 后缺口持续走高，买盘真实")
            } else if stability >= 0.8 {
                reasons.append("锁定期缺口维持稳定")
            } else if stability <= 0.4 {
                risks.append("9:20 后缺口明显回落，疑有大单撤单")
            }

            // ③ 量能（0-30）：核心分水岭
            //    量比口径优先；缺失时用竞价换手率（阈值按竞价时段校准：0.3% 即活跃）
            if volRatio > 0 {
                // 量比 1 = 与近期平均水平持平；3 以上为强
                let r = min(volRatio, 8.0)
                score += 30.0 * (log(1 + r) / log(9.0))
                if volRatio >= 3 {
                    reasons.append(String(format: "竞价量比 %.1f，资金抢筹明显", volRatio))
                } else if volRatio >= 1.5 {
                    reasons.append(String(format: "竞价量比 %.1f，量能配合", volRatio))
                } else if volRatio < 0.8 {
                    risks.append("竞价量比偏低")
                }
            } else if turnover > 0 {
                // 竞价换手（09:20-09:25 窗口）：0.8% 已属强势
                let t = min(turnover, 3.0)
                score += 30.0 * (log(1 + t * 3) / log(10.0))
                if turnover >= 0.8 {
                    reasons.append(String(format: "竞价换手 %.2f%%，资金积极", turnover))
                } else if turnover >= 0.3 {
                    reasons.append(String(format: "竞价换手 %.2f%%，量能配合", turnover))
                } else if turnover < 0.08 {
                    risks.append("竞价换手偏低，关注度不足")
                }
            } else {
                score += 6
                risks.append("量能数据缺失")
            }

            // ④ 竞价额（0-12）：资金体量绝对量
            if latest.amount > 0 {
                let a = min(latest.amount, 2e8)
                score += 12.0 * (log(1 + a / 1e6) / log(201.0))
                if latest.amount >= 5e7 {
                    reasons.append(String(format: "竞价额 %.2f 亿", latest.amount / 1e8))
                } else if latest.amount < 2e6 {
                    risks.append("竞价额过小，流动性不足")
                }
            }

            // ⑤ 市值弹性（-8 ~ +6）
            if m.floatCap > 0 {
                if m.floatCap <= 80 { score += 6; reasons.append("小盘股，开盘弹性好") }
                else if m.floatCap <= 200 { score += 3 }
                else if m.floatCap >= 500 { score -= 8; risks.append("流通盘偏大，拉抬需巨量") }
            }

            // ⑥ 矛盾信号扣分
            if gap > 5 && volRatio > 0 && volRatio < 1.2 {
                score -= 12
                risks.append("大幅高开但量能未跟上，谨慎")
            }
            if gap > 3 && stability < 0.5 {
                score -= 10
                risks.append("高开但缺口回落，强度存疑")
            }
            if gap < 1 && (volRatio > 0 && volRatio < 1.0) {
                score -= 6
                risks.append("高开微幅且无量，缺乏动能")
            }

            score = min(100, max(0, score))

            let grade: String
            switch score {
            case 78...: grade = "重点"
            case 65..<78: grade = "关注"
            case 52..<65: grade = "观察"
            default: grade = "一般"
            }

            // ===== 大涨概率估算 =====
            // 目标：预估「开盘后涨幅突破 3%」的可能性。
            // 依据竞价强度三要素加权，再按历史经验做概率映射。
            let (surge, surgeLabel) = estimateSurge(
                gap: gap, stability: stability, volRatio: volRatio,
                turnover: turnover, amount: latest.amount,
                floatCap: m.floatCap, score: score
            )

            picks.append(AuctionPick(
                security: m.security,
                name: m.name,
                matchPrice: latest.matchPrice,
                prevClose: prevClose,
                gapPct: gap,
                volume: latest.volume,
                amount: latest.amount,
                volumeRatio: volRatio,
                turnover: turnover,
                floatCap: m.floatCap,
                industry: m.industry,
                stability: stability,
                gapAtLock: gapAtLock,
                score: score,
                grade: grade,
                surgeProbability: surge,
                surgeLabel: surgeLabel,
                reasons: Array(reasons.prefix(4)),
                risks: Array(risks.prefix(3))
            ))
        }

        picks.sort { $0.score > $1.score }
        return picks
    }

    /// 估算「开盘后涨幅突破 3%」的概率。
    ///
    /// 经验依据（A股竞价研究）：
    /// - 高开 2~5% 且竞价量能强、锁定后缺口走高 → 大涨概率显著提升；
    /// - 高开过高（>7%）反而因获利盘涌出概率下降；
    /// - 缩量高开多为诱多，概率低。
    ///
    /// 映射到 0~100 的百分比，并给出易懂分档。
    private func estimateSurge(
        gap: Double, stability: Double, volRatio: Double,
        turnover: Double, amount: Double, floatCap: Double, score: Double
    ) -> (Double, String) {

        // 基础概率：从综合评分映射。斜率调小，避免高分票全部顶到上限。
        var p = 12.0 + (score - 40.0) * 0.42

        // ── 缺口修正：2~5% 最佳，过高反而扣
        if gap >= 2 && gap <= 5 { p += 8 }
        else if gap > 5 && gap <= 7 { p += 3 }
        else if gap > 7 && gap <= 9 { p -= 3 }
        else if gap > 9 { p -= 8 }
        else if gap < 1 { p -= 5 }

        // ── 稳定性修正：锁定期走高是最强信号
        if stability >= 0.95 { p += 10 }
        else if stability >= 0.8 { p += 5 }
        else if stability < 0.4 { p -= 10 }
        else if stability < 0.6 { p -= 5 }

        // ── 量能修正
        // 量比口径最可信；换手率仅在非竞价时段作为近似，且需归一化到竞价尺度
        // （竞价换手通常 0.1~1%，全天换手 2~20%，不能直接用全天值）
        var volStrength = 0.0
        if volRatio > 0 {
            volStrength = volRatio                       // 量比，直接比较
        } else if turnover > 0 {
            volStrength = turnover / 0.6                 // 换手归一到「1.0 = 0.6% 换手」
            // 全天口径的换手会远高于竞价尺度，超过 8 倍视为口径失真，不参与加分
            if volStrength > 8 { volStrength = 0 }
        }
        if volStrength >= 4 { p += 12 }
        else if volStrength >= 2.5 { p += 8 }
        else if volStrength >= 1.5 { p += 4 }
        else if volStrength > 0 && volStrength < 0.8 { p -= 5 }

        // ── 竞价额：资金体量
        if amount >= 1e8 { p += 6 }
        else if amount >= 3e7 { p += 4 }
        else if amount < 5e6 { p -= 4 }

        // ── 市值：小盘更容易被拉
        if floatCap > 0 {
            if floatCap <= 80 { p += 5 }
            else if floatCap >= 500 { p -= 4 }
        }

        // 上限压缩：竞价选股再准也难超 55%（开盘后的资金行为不可预知）。
        // 仅对高分端做软压缩，低分端保持原样，避免全部塌到下限而失去区分度。
        if p > 30 {
            p = 30 + (p - 30) * 0.55
        }
        p = min(55, max(3, p))

        let label: String
        switch p {
        case 45...: label = "高"
        case 30..<45: label = "较高"
        case 18..<30: label = "中等"
        case 10..<18: label = "偏低"
        default: label = "低"
        }
        return (p, label)
    }

    /// 清空当日采样
    func reset() {
        samples.removeAll()
        lastAmount.removeAll()
    }

    var candidateCount: Int { candidates.count }
    var sampleCodeCount: Int { samples.count }

    // MARK: - 解析辅助

    private func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d.isFinite ? d : 0 }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }

    private func num2(_ s: String) -> Double {
        Double(s.trimmingCharacters(in: .whitespaces)) ?? 0
    }
}
