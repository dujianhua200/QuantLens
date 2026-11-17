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
