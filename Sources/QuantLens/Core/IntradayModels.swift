import Foundation

// MARK: - 分时数据

/// 分时图的一个点
struct IntradayPoint: Identifiable, Hashable {
    let id = UUID()
    /// 交易时间（含日期）
    var time: Date
    /// 当前价
    var price: Double
    /// 均价（成交额/成交量，即分时图里的黄线）
    var avgPrice: Double
    /// 本分钟成交量（手）
    var volume: Double
    /// 累计成交量（手）
    var cumVolume: Double
    /// 累计成交额（元）
    var cumAmount: Double
}

/// 分时数据包
struct IntradayData {
    var security: Security
    var previousClose: Double
    /// 全部分时点（240 个左右）
    var points: [IntradayPoint]
    /// 今日最高/最低（取自分时序列）
    var dayHigh: Double
    var dayLow: Double
    /// 更新时间
    var updatedAt: Date

    /// 涨跌幅（相对昨收）
    func changePct(at index: Int) -> Double {
        guard previousClose > 0, index >= 0, index < points.count else { return 0 }
        return (points[index].price / previousClose - 1) * 100
    }

    var lastPrice: Double { points.last?.price ?? previousClose }
    var lastChangePct: Double {
        guard previousClose > 0 else { return 0 }
        return (lastPrice / previousClose - 1) * 100
    }
}

// MARK: - 五档盘口

/// 一档报价
struct OrderBookLevel: Hashable {
    /// 1~5，1 表示最贴近现价
    var level: Int
    var price: Double
    /// 挂单量（手）
    var volume: Double
}

/// 五档盘口 + 内外盘
struct OrderBook: Hashable {
    var bids: [OrderBookLevel]      // 买1~买5，bids[0] 是买1
    var asks: [OrderBookLevel]      // 卖1~卖5，asks[0] 是卖1
    /// 外盘（主动买入量，手）
    var outerVolume: Double
    /// 内盘（主动卖出量，手）
    var innerVolume: Double
    /// 时间
    var timestamp: Date

    /// 委比 = (买量 - 卖量) / (买量 + 卖量) × 100%
    var bidAskRatio: Double {
        let bid = bids.map(\.volume).reduce(0, +)
        let ask = asks.map(\.volume).reduce(0, +)
        let total = bid + ask
        return total > 0 ? (bid - ask) / total * 100 : 0
    }

    /// 委差（手）
    var bidAskDiff: Double {
        bids.map(\.volume).reduce(0, +) - asks.map(\.volume).reduce(0, +)
    }

    /// 主动买入占比
    var outerRatio: Double {
        let total = outerVolume + innerVolume
        return total > 0 ? outerVolume / total * 100 : 0
    }

    /// 卖一价（涨停时用来判断封板）
    var ask1: Double? { asks.first?.price }
    var bid1: Double? { bids.first?.price }
}

// MARK: - 逐笔成交

enum TradeSide: String, Hashable {
    case buy = "B"      // 主动买入（外盘）
    case sell = "S"     // 主动卖出（内盘）
    case neutral = "M"  // 中性

    var label: String {
        switch self {
        case .buy: return "买"
        case .sell: return "卖"
        case .neutral: return "中"
        }
    }

    var shortLabel: String {
        switch self {
        case .buy: return "B"
        case .sell: return "S"
        case .neutral: return "M"
        }
    }
}

/// 一笔成交
struct Trade: Identifiable, Hashable {
    let id = UUID()
    /// 成交序号（当日累计）
    var sequence: Int
    var time: Date
    var price: Double
    /// 涨跌（相对前一笔）
    var change: Double
    /// 成交量（手）
    var volume: Double
    /// 成交额（元）
    var amount: Double
    var side: TradeSide

    /// 是否大单。A股习惯：>=500手 或 >=100万元 视为大单
    var isLargeOrder: Bool {
        volume >= 500 || amount >= 1_000_000
    }

    /// 是否特大单：>=2000手 或 >=500万元
    var isHugeOrder: Bool {
        volume >= 2000 || amount >= 5_000_000
    }

    /// 金额（万元）
    var amountInWan: Double { amount / 10_000 }
}

/// 大单统计
struct LargeOrderStats: Hashable {
    var buyCount = 0
    var buyVolume: Double = 0
    var buyAmount: Double = 0
    var sellCount = 0
    var sellVolume: Double = 0
    var sellAmount: Double = 0

    var netAmount: Double { buyAmount - sellAmount }
    var totalAmount: Double { buyAmount + sellAmount }
    var buyRatio: Double {
        totalAmount > 0 ? buyAmount / totalAmount * 100 : 0
    }

    mutating func add(_ t: Trade) {
        if t.side == .buy {
            buyCount += 1
            buyVolume += t.volume
            buyAmount += t.amount
        } else if t.side == .sell {
            sellCount += 1
            sellVolume += t.volume
            sellAmount += t.amount
        }
    }

    static func summarize(_ trades: [Trade], threshold: LargeThreshold) -> LargeOrderStats {
        var s = LargeOrderStats()
        for t in trades where threshold.matches(t) {
            s.add(t)
        }
        return s
    }
}

/// 大单阈值（可调）
enum LargeThreshold: String, CaseIterable, Identifiable {
    case medium = "100手"
    case large = "500手"
    case huge = "2000手"

    var id: String { rawValue }

    var volumeThreshold: Double {
        switch self {
        case .medium: return 100
        case .large: return 500
        case .huge: return 2000
        }
    }

    var amountThreshold: Double {
        switch self {
        case .medium: return 1_000_000     // 100万
        case .large: return 3_000_000      // 300万
        case .huge: return 10_000_000      // 1000万
        }
    }

    func matches(_ t: Trade) -> Bool {
        t.volume >= volumeThreshold || t.amount >= amountThreshold
    }
}

// MARK: - 大单预警

struct LargeOrderAlert: Identifiable, Hashable {
    let id = UUID()
    var security: Security
    var trade: Trade
    var level: AlertLevel

    enum AlertLevel: String {
        case huge = "特大单"
        case large = "大单"

        var color: String {
            switch self {
            case .huge: return "huge"
            case .large: return "large"
            }
        }
    }
}

// MARK: - 大单扫描结果（跨标的）

struct LargeOrderScanResult: Identifiable, Hashable {
    var security: Security
    var buyCount: Int
    var buyAmount: Double
    var sellCount: Int
    var sellAmount: Double
    var netAmount: Double
    /// 主动买入金额占比 %
    var buyRatio: Double

    var id: String { security.id }
}
