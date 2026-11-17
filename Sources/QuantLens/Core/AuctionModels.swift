import Foundation

// MARK: - 集合竞价选股模型

/// 竞价阶段（A 股规则）
/// - 09:15–09:20 可撤单，虚假挂单集中在此，数据参考价值低
/// - 09:20–09:25 不可撤单，委托真实，是判断开盘强度的黄金窗口
/// - 09:25 一次性撮合产生开盘价
enum AuctionPhase: String {
    case idle = "未开始"
    case earlyNoisy = "可撤单期"       // 09:15-09:20
    case locked = "不可撤单期"          // 09:20-09:25
    case settled = "已定价"             // 09:25 之后
    case closed = "已收盘"

    var hint: String {
        switch self {
        case .idle: return "等待 09:15 竞价开始"
        case .earlyNoisy: return "09:20 前可撤单，虚假挂单多，参考价值低"
        case .locked: return "09:20 后不可撤单，此窗口数据最真实"
        case .settled: return "09:25 已撮合，开盘价确定"
        case .closed: return "今日竞价已结束"
        }
    }
}

/// 单只股票的竞价过程快照（每个采样点一条）
struct AuctionSample: Hashable {
    var at: Date
    /// 竞价虚拟撮合价（09:25 后即开盘价）
    var matchPrice: Double
    /// 相对昨收的高开幅度 %
    var gapPct: Double
    /// 竞价累计成交量（手）
    var volume: Double
    /// 竞价累计成交额（元）
    var amount: Double
    /// 该阶段内量能增量（手）——用于判断竞价过程中是否持续放量
    var volumeDelta: Double
    /// 委买比 % = (买量 - 卖量) / (买量 + 卖量) × 100，取自同一行情响应的五档字段；
    /// 盘口字段缺失时为 0（不参与加分）
    var bidAskRatio: Double = 0
}

/// 竞价分类：按缺口位置与历史基因划分的观察类别，不是操作建议。
enum AuctionClass: String, Hashable {
    case normal = "常规"
    case sweetSpot = "甜点"
    case cashOutRisk = "兑现风险"
    case panicRepair = "恐慌修复"
}

/// 竞价选股结果
struct AuctionPick: Identifiable, Hashable {
    var security: Security
    var name: String
    var matchPrice: Double
    var prevClose: Double
    var gapPct: Double            // 高开幅度 %
    var volume: Double            // 竞价量（手）
    var amount: Double            // 竞价额（元）
    var volumeRatio: Double       // 竞价量比（竞价量 / 近期日均分钟量）
    var turnover: Double          // 竞价换手率 %
    var floatCap: Double          // 流通市值（亿）
    var industry: String

    /// 稳定性：09:20 锁定后高开幅度是否维持/走高
    /// 1.0 = 全程稳定上行；0 = 9:20 后大幅回落（撤单假象）
    var stability: Double
    /// 9:20 时的开盘缺口（用于对比回落）
    var gapAtLock: Double

    /// 综合评分 0-100
    var score: Double
    /// 分级
    var grade: String
    /// 大涨概率（0-100）：综合竞价强度估算的「开盘后涨幅超 3%」概率
    var surgeProbability: Double
    /// 概率分档
    var surgeLabel: String
    /// 关键依据
    var reasons: [String]
    /// 风险提示
    var risks: [String]

    /// 竞价分类（甜点 / 兑现风险 / 恐慌修复 / 常规）
    var auctionClass: AuctionClass = .normal
    /// 委买比 %（最新采样点的五档盘口）
    var bidAskRatio: Double = 0
    /// 昨日是否涨停（历史复核，日 K 口径；未复核时为 false 且 historyKnown 为 false）
    var prevLimitUp: Bool = false
    /// 以昨日为终点的连续涨停天数
    var boardStreak: Int = 0
    /// 昨日涨跌幅 %
    var prevDayChangePct: Double = 0
    /// 昨日收盘在当日区间的位置 0~1（越大收盘越强）
    var prevCloseStrength: Double = 0
    /// 历史基因是否已复核
    var historyKnown: Bool = false

    var id: String { security.id }

    var amountInYi: Double { amount / 1e8 }
}

/// 竞价扫描运行状态
struct AuctionRunState {
    var phase: AuctionPhase = .idle
    var isRunning = false
    var candidates: Int = 0
    var scanned: Int = 0
    var lastSampleAt: Date?
    var nextScanAt: Date?
    var message: String = ""
    var picks: [AuctionPick] = []
    var tradeDate: String = ""
}
