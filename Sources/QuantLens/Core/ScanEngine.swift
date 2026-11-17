import Foundation

// MARK: - 扫描结果

struct ScanResult: Identifiable, Hashable {
    var security: Security
    var quote: Quote?
    var price: Double
    var changePct: Double

    /// 四类信号评分
    var buyScore: Double
    var riskScore: Double
    var accumulateScore: Double
    var distributeScore: Double

    /// 综合排名分（用于排序）
    var opportunityScore: Double

    /// 最佳信号类型与分数
    var bestKind: SignalKind?
    var bestScore: Double

    /// 关键依据（最多3条）
    var topReasons: [String]

    /// 最近支撑 / 压力
    var support: Double?
    var resistance: Double?

    /// 风险收益比
    var riskReward: Double?

    /// 建议入场区间
    var entryZone: (low: Double, high: Double)?

    /// 显性买卖点记录（由本次分析的信号标记转译，见 TradePoint）
    var tradePoints: [TradePoint] = []

    /// 一句话结论
    var verdict: String

    /// 结论分级
    var grade: ScanGrade

    /// 数据处理时间
    var scannedAt: Date = Date()

    var id: String { security.id }

    static func == (lhs: ScanResult, rhs: ScanResult) -> Bool {
        lhs.security.id == rhs.security.id && lhs.scannedAt == rhs.scannedAt
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(security.id)
        hasher.combine(scannedAt)
    }
}

// MARK: - 结论分级

enum ScanGrade: String, Comparable {
    case strong = "强烈推荐"
    case buy = "可买入"
    case watch = "观察"
    case none = "无机会"
    case avoid = "回避"

    var sortOrder: Int {
        switch self {
        case .strong: return 0
        case .buy: return 1
        case .watch: return 2
        case .none: return 3
        case .avoid: return 4
        }
    }

    static func < (lhs: ScanGrade, rhs: ScanGrade) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

// MARK: - 扫描引擎

/// 多标的并发扫描器。
///
/// 短线交易的核心矛盾是「机会多但时间少」，所以扫描环节要解决三件事：
/// 1. 并发拉取全部自选股数据（受控并发，避免打爆免费接口）
/// 2. 对每只股票跑完整信号引擎，算出可比较的机会分
/// 3. 给出明确的进场区间、止损位、目标位和风险收益比
enum ScanEngine {

    struct Options {
        var period: KPeriod = .day
        var maxConcurrent: Int = 4
        /// 只输出机会分高于该值的标的
        var minOpportunity: Double = 0
    }

    /// 扫描一批标的
    static func scan(securities: [Security],
                     options: Options = Options(),
                     progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [ScanResult] {
        guard !securities.isEmpty else { return [] }

        var results: [ScanResult] = []
        let total = securities.count
        var completed = 0

        // 分批并发，控制请求速率
        let batchSize = max(1, options.maxConcurrent)
        var index = 0
        while index < total {
            let end = min(index + batchSize, total)
            let batch = Array(securities[index..<end])

            await withTaskGroup(of: ScanResult?.self) { group in
                for sec in batch {
                    group.addTask {
                        await evaluate(sec, period: options.period)
                    }
                }
                for await r in group {
                    if let r { results.append(r) }
                }
            }

            completed += batch.count
            progress?(completed, total)
            index = end

            // 批次之间留间隔，避免触发免费接口限流
            if index < total {
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
        }

        return results
            .filter { $0.opportunityScore >= options.minOpportunity }
            .sorted { $0.opportunityScore > $1.opportunityScore }
    }

    // MARK: - 单标的评估

    static func evaluate(_ security: Security, period: KPeriod) async -> ScanResult? {
        let data = await MarketService.shared.load(security: security, period: period)
        guard data.candles.count >= 60 else { return nil }

        let analysis = SignalEngine.analyze(data: data, period: period)
        let ctx = analysis.context
        let ev = analysis.eval
        let price = ctx.currentPrice

        // 支撑与压力
        let support = analysis.supports.max(by: { $0.price < $1.price })
        let resistance = analysis.resistances.min(by: { $0.price < $1.price })

        // 止损：最近强支撑下方 1 个 ATR，或现价下方 4%
        let atr = ctx.atr.value(ctx.lastIndex) ?? price * 0.02
        let stopBySupport = (support?.price ?? price) - atr * 0.8
        let stopByPercent = price * 0.96
        let stop = max(stopBySupport, stopByPercent)
        let stopLossPct = (price - stop) / price * 100

        // 目标：最近压力位，或现价上方 2 倍风险
        let riskAmount = price - stop
        let targetByResistance = resistance?.price ?? price + riskAmount * 2
        let target = max(targetByResistance, price + riskAmount * 1.5)
        let riskReward = riskAmount > 0 ? (target - price) / riskAmount : 0

        // 机会分（0~100）
        //
        // 设计要点：
        // - 以「正向信号强度」为基底，而不是从 0 分开始做加减法
        //   否则正向信号本身只有 20~60 分时，扣完永远是低分，无法区分优劣
        // - 风险类信号按比例折扣，而非等量扣减
        // - 风险收益比是短线交易的核心门槛，权重最高
        let positive = max(ev.buy.score, ev.accumulate.score)     // 取更强的正向信号
        var opportunity = positive * 0.55                          // 基底最多 55 分

        // 买入与进场同时成立，共振加分
        if ev.buy.score >= 45 && ev.accumulate.score >= 45 {
            opportunity += 12
        }
        // 趋势加成
        if let trend = ctx.trend {
            switch trend.direction {
            case .strongUp: opportunity += 14
            case .up: opportunity += 8
            case .sideways: opportunity += 0
            case .down: opportunity -= 10
            case .strongDown: opportunity -= 22
            }
        }
        // 风险收益比：短线唯一硬门槛
        if riskReward >= 3.0 { opportunity += 20 }
        else if riskReward >= 2.0 { opportunity += 14 }
        else if riskReward >= 1.5 { opportunity += 6 }
        else if riskReward < 1.0 { opportunity -= 18 }
        else { opportunity -= 6 }

        // 风险与撤退信号按比例折扣（不是直接减分，避免一票否决）
        let riskDrag = ev.risk.score * 0.42 + ev.distribute.score * 0.55
        opportunity -= riskDrag

        // 止损宽度：>8% 短线无法接受
        if stopLossPct > 8 { opportunity -= 20 }
        else if stopLossPct > 6 { opportunity -= 10 }
        else if stopLossPct <= 4 { opportunity += 4 }

        // 极端超买
        if let rsi = ctx.rsi14.value(ctx.lastIndex) {
            if rsi > 80 { opportunity -= 15 }
            else if rsi > 75 { opportunity -= 7 }
        }
        // 距离压力太近，上方空间不足
        if let res = resistance {
            let room = (res.price - price) / price * 100
            if room < 1.5 { opportunity -= 12 }
            else if room < 3.0 { opportunity -= 5 }
        }

        opportunity = max(0, min(100, opportunity))

        // 最佳信号
        let candidates: [(SignalKind, Double)] = [
            (.buy, ev.buy.score),
            (.accumulate, ev.accumulate.score),
            (.risk, ev.risk.score),
            (.distribute, ev.distribute.score)
        ]
        // 优先展示正向信号；若风险显著更高则展示风险
        let bestPositive = candidates.filter { $0.0 == .buy || $0.0 == .accumulate }.max { $0.1 < $1.1 }
        let bestNegative = candidates.filter { $0.0 == .risk || $0.0 == .distribute }.max { $0.1 < $1.1 }
        let best: (SignalKind, Double)?
        if let bp = bestPositive, let bn = bestNegative {
            best = bn.1 > bp.1 + 12 ? bn : bp
        } else {
            best = bestPositive ?? bestNegative
        }

        // 依据：取最佳信号的理由
        let reasons: [String]
        switch best?.0 {
        case .buy: reasons = Array(ev.buy.reasons.prefix(3))
        case .risk: reasons = Array(ev.risk.reasons.prefix(3))
        case .accumulate: reasons = Array(ev.accumulate.reasons.prefix(3))
        case .distribute: reasons = Array(ev.distribute.reasons.prefix(3))
        case nil: reasons = []
        }

        // 建议入场区间：支撑上方 0~1.2%
        let entryLow = support.map { max($0.price * 1.000, price * 0.985) } ?? price * 0.99
        let entryHigh = price * 1.005

        // 结论分级：必须给出明确的可执行判断，而不是全部"观察"
        //
        // 分级依据（按优先级）：
        // 1. 风险否决项（撤退强、趋势强下跌、止损过宽）→ 直接回避
        // 2. 机会分 + 风险收益比 → 推荐 / 关注 / 观察
        // 分级判断抽成纯函数 grade(...)，便于单测边界；evaluate 只传值，不改口径。
        let (grade, verdict) = Self.grade(
            opportunity: opportunity,
            riskReward: riskReward,
            riskScore: ev.risk.score,
            distributeScore: ev.distribute.score,
            isStrongDown: ctx.trend?.direction == .strongDown,
            stopLossPct: stopLossPct,
            entryLow: entryLow
        )

        let quote = data.quote
        let changePct = quote?.changePct ?? 0

        return ScanResult(
            security: data.security,
            quote: quote,
            price: price,
            changePct: changePct,
            buyScore: ev.buy.score,
            riskScore: ev.risk.score,
            accumulateScore: ev.accumulate.score,
            distributeScore: ev.distribute.score,
            opportunityScore: opportunity,
            bestKind: best?.0,
            bestScore: best?.1 ?? 0,
            topReasons: reasons,
            support: support?.price,
            resistance: resistance?.price,
            riskReward: riskReward,
            entryZone: (entryLow, entryHigh),
            tradePoints: TradePoint.dailyPoints(from: analysis),
            verdict: verdict,
            grade: grade
        )
    }

    // MARK: - 结论分级（纯函数，可单测）

    /// 五档分级判断。输入全部为标量，与 evaluate 内的原内联逻辑逐字一致，
    /// 抽取只是为了让分级边界可测试，不改变任何阈值与文案。
    static func grade(opportunity: Double,
                      riskReward: Double,
                      riskScore: Double,
                      distributeScore: Double,
                      isStrongDown: Bool,
                      stopLossPct: Double,
                      entryLow: Double) -> (grade: ScanGrade, verdict: String) {
        let hasStrongExit = distributeScore >= 60
        let tooWide = stopLossPct > 8

        if hasStrongExit {
            return (.avoid, "主力撤退信号明确，资金在流出，不介入")
        } else if isStrongDown {
            return (.avoid, "中期趋势弱势下跌，左侧接刀风险高")
        } else if tooWide {
            return (.avoid, "止损位需放到 \(Fmt.price(stopLossPct, decimals: 1))%，短线风险不可控")
        } else if opportunity >= 62, riskReward >= 2.0, riskScore < 60 {
            return (.strong, "多因子共振，盈亏比 \(Fmt.price(riskReward, decimals: 1))，可分批进场")
        } else if opportunity >= 48, riskReward >= 1.5, riskScore < 70 {
            return (.buy, "买点成立，等回踩 \(Fmt.price(entryLow)) 附近确认后进场")
        } else if opportunity >= 34 {
            return (.watch, "结构偏多但信号未确认，加入观察")
        } else if riskScore >= 60 {
            return (.watch, "存在 \(Int(riskScore)) 分风险信号，观望")
        } else {
            return (.none, "无明确机会")
        }
    }
}
