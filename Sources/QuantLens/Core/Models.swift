import Foundation

// MARK: - 市场

enum Market: String, Codable, Hashable, CaseIterable {
    case sh, sz, bj, hk, us, index

    var label: String {
        switch self {
        case .sh: return "沪A"
        case .sz: return "深A"
        case .bj: return "北交所"
        case .hk: return "港股"
        case .us: return "美股"
        case .index: return "指数"
        }
    }

    /// 涨跌停幅度（用于风险提示时的涨幅阈值参考）
    var limitUp: Double {
        switch self {
        case .sh, .sz: return 0.10
        case .bj: return 0.30
        case .hk, .us, .index: return 0
        }
    }
}

// MARK: - 周期

enum KPeriod: String, Codable, Hashable, CaseIterable, Identifiable {
    case m5, m15, m30, m60, day, week, month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .m5: return "5分"
        case .m15: return "15分"
        case .m30: return "30分"
        case .m60: return "60分"
        case .day: return "日线"
        case .week: return "周线"
        case .month: return "月线"
        }
    }

    var isIntraday: Bool {
        switch self {
        case .m5, .m15, .m30, .m60: return true
        default: return false
        }
    }

    /// 每根K线覆盖的交易日比例，用于把指标参数按周期缩放
    var barsPerDay: Double {
        switch self {
        case .m5: return 48
        case .m15: return 16
        case .m30: return 8
        case .m60: return 4
        case .day: return 1
        case .week: return 0.2
        case .month: return 0.046
        }
    }
}

// MARK: - 标的

struct Security: Identifiable, Hashable, Codable {
    let symbol: String        // 原始代码，如 600519 / 00700 / AAPL
    let name: String
    let market: Market

    var id: String { "\(market.rawValue).\(symbol)" }

    /// 腾讯行情代码。指数市场直接以完整代码存储（sh000001 / hkHSI / us.IXIC）
    var tencentCode: String {
        switch market {
        case .index: return symbol
        case .sh: return "sh\(symbol)"
        case .sz: return "sz\(symbol)"
        case .bj: return "bj\(symbol)"
        case .hk: return "hk\(symbol)"
        case .us: return "us\(symbol.uppercased())"
        }
    }

    var displayCode: String {
        switch market {
        case .us: return symbol.uppercased()
        case .index:
            // 去掉 sh/sz/hk/us 前缀
            if symbol.count > 2, symbol.hasPrefix("sh") || symbol.hasPrefix("sz") || symbol.hasPrefix("hk") {
                return String(symbol.dropFirst(2))
            }
            if symbol.hasPrefix("us.") { return String(symbol.dropFirst(3)) }
            return symbol
        default: return symbol
        }
    }
}

// MARK: - K线

struct Candle: Identifiable, Hashable {
    let date: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double
    let amount: Double

    var id: Date { date }

    var isUp: Bool { close >= open }
    var body: Double { abs(close - open) }
    var range: Double { max(high - low, 0.0001) }
    var upperShadow: Double { high - max(open, close) }
    var lowerShadow: Double { min(open, close) - low }

    /// 收盘价在当日区间的位置 0~1
    var closePosition: Double {
        guard range > 0 else { return 0.5 }
        return (close - low) / range
    }

    /// 实体占振幅比例，判断滞涨/十字星
    var bodyRatio: Double { body / range }

    /// 上影线占振幅比例
    var upperShadowRatio: Double { upperShadow / range }

    /// 下影线占振幅比例
    var lowerShadowRatio: Double { lowerShadow / range }
}

// MARK: - 实时快照

struct Quote: Identifiable, Hashable {
    var security: Security
    var price: Double
    var prevClose: Double
    var open: Double
    var high: Double
    var low: Double
    var volume: Double          // 手
    var amount: Double          // 元
    var turnoverRate: Double    // 换手率 %
    var pe: Double
    var pb: Double
    var totalMarketCap: Double  // 亿元
    var floatMarketCap: Double
    var amplitude: Double       // 振幅 %
    var timestamp: Date

    var id: String { security.id }

    var change: Double { price - prevClose }
    var changePct: Double { prevClose > 0 ? change / prevClose * 100 : 0 }
    var isUp: Bool { change >= 0 }
}

// MARK: - 资金流

struct FundFlow: Hashable {
    /// 主力净流入（元）
    var mainNet: Double
    /// 超大单净流入
    var superLargeNet: Double
    /// 大单净流入
    var largeNet: Double
    /// 中单净流入
    var mediumNet: Double
    /// 小单净流入
    var smallNet: Double
    /// 主力净占比 %
    var mainRatio: Double
    var date: Date?
}

// MARK: - 数据包

struct StockData: Hashable {
    var security: Security
    var quote: Quote?
    var candles: [Candle]
    var fundFlow: FundFlow?
    var fundFlowHistory: [FundFlow]
}

// MARK: - 信号

enum SignalKind: String, CaseIterable, Codable, Identifiable {
    case buy, risk, accumulate, distribute

    var id: String { rawValue }

    var label: String {
        switch self {
        case .buy: return "买入机会"
        case .risk: return "风险警示"
        case .accumulate: return "主力进场"
        case .distribute: return "主力撤退"
        }
    }

    var shortLabel: String {
        switch self {
        case .buy: return "买"
        case .risk: return "险"
        case .accumulate: return "进"
        case .distribute: return "撤"
        }
    }

    var symbolName: String {
        switch self {
        case .buy: return "arrow.up.right.circle.fill"
        case .risk: return "exclamationmark.triangle.fill"
        case .accumulate: return "arrow.down.left.circle.fill"
        case .distribute: return "arrow.up.right.square.fill"
        }
    }

    /// 排序权重：风险优先展示
    var priority: Int {
        switch self {
        case .risk: return 0
        case .distribute: return 1
        case .accumulate: return 2
        case .buy: return 3
        }
    }
}

/// 副图指标类型
enum SubIndicator: String, CaseIterable, Identifiable {
    case volume, macd, kdj, rsi

    var id: String { rawValue }

    var label: String {
        switch self {
        case .volume: return "成交量"
        case .macd: return "MACD"
        case .kdj: return "KDJ"
        case .rsi: return "RSI"
        }
    }
}

/// 单条信号
struct TradingSignal: Identifiable, Hashable {
    let id = UUID()
    var kind: SignalKind
    var score: Double            // 0~100
    var title: String
    var reasons: [String]
    var price: Double
    var date: Date
    var period: KPeriod

    var level: SignalLevel {
        switch score {
        case 80...: return .strong
        case 65..<80: return .medium
        case 50..<65: return .weak
        default: return .none
        }
    }

    var isActionable: Bool { score >= 50 }
}

enum SignalLevel: String {
    case strong, medium, weak, none

    var label: String {
        switch self {
        case .strong: return "强"
        case .medium: return "中"
        case .weak: return "弱"
        case .none: return "无"
        }
    }
}

// MARK: - 支撑压力

enum LevelKind: String, Hashable {
    case support, resistance

    var label: String {
        switch self {
        case .support: return "支撑"
        case .resistance: return "压力"
        }
    }
}

enum LevelSource: String, Hashable, CaseIterable {
    case swing, volumeProfile, movingAverage, fibonacci, previousExtreme

    var label: String {
        switch self {
        case .swing: return "摆动点"
        case .volumeProfile: return "成交密集区"
        case .movingAverage: return "均线"
        case .fibonacci: return "斐波那契"
        case .previousExtreme: return "前高低点"
        }
    }

    var shortLabel: String {
        switch self {
        case .swing: return "摆动"
        case .volumeProfile: return "筹码"
        case .movingAverage: return "均线"
        case .fibonacci: return "斐波"
        case .previousExtreme: return "前高"
        }
    }

    /// 各来源基础权重：成交密集区与摆动点最可靠
    var weight: Double {
        switch self {
        case .volumeProfile: return 1.35
        case .swing: return 1.25
        case .movingAverage: return 1.0
        case .previousExtreme: return 0.95
        case .fibonacci: return 0.7
        }
    }
}

struct PriceLevel: Identifiable, Hashable {
    let id = UUID()
    var price: Double
    var kind: LevelKind
    var score: Double                  // 0~100 综合强度
    var sources: Set<LevelSource>
    var touches: Int                   // 触碰次数
    var distancePct: Double            // 距现价百分比

    var strengthLabel: String {
        switch score {
        case 75...: return "极强"
        case 60..<75: return "强"
        case 45..<60: return "中"
        default: return "弱"
        }
    }
}

// MARK: - 回测

struct BacktestResult: Hashable {
    var kind: SignalKind
    var samples: Int
    var winRate: Double        // 0~1
    /// 平均前瞻收益
    var avgReturn: [Int: Double]   // 天数 -> 收益%
    var bestTrade: Double
    var worstTrade: Double
}

// MARK: - 工具

enum Fmt {
    static func price(_ v: Double, decimals: Int = 2) -> String {
        String(format: "%.\(decimals)f", v)
    }

    static func pct(_ v: Double, decimals: Int = 2, sign: Bool = true) -> String {
        let s = String(format: "%.\(decimals)f", v)
        if sign && v > 0 { return "+" + s + "%" }
        return s + "%"
    }

    /// 大额金额：万 / 亿
    static func money(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1e8 { return String(format: "%.2f亿", v / 1e8) }
        if a >= 1e4 { return String(format: "%.2f万", v / 1e4) }
        return String(format: "%.0f", v)
    }

    /// 成交量（手）
    static func volume(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1e8 { return String(format: "%.2f亿手", v / 1e8) }
        if a >= 1e4 { return String(format: "%.2f万手", v / 1e4) }
        return String(format: "%.0f手", v)
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    static let intradayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    static func date(_ d: Date, intraday: Bool = false) -> String {
        intraday ? intradayFormatter.string(from: d) : dateFormatter.string(from: d)
    }
}
