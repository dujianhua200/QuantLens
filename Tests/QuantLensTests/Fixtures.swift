import Foundation
@testable import QuantLens

// MARK: - 确定性合成夹具（不联网）

/// 固定时间原点：2023-11-14 22:13:20 UTC。所有夹具日期由此递增，与真实日历无关。
enum Fixtures {
    static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    static let security = Security(symbol: "600519", name: "贵州茅台", market: .sh)

    static func date(days: Int) -> Date {
        baseDate.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    static func date(minutes: Int) -> Date {
        baseDate.addingTimeInterval(TimeInterval(minutes) * 60)
    }

    static func candle(day: Int, open: Double, high: Double, low: Double, close: Double,
                       volume: Double = 1000, amount: Double = 0) -> Candle {
        Candle(date: date(days: day), open: open, high: high, low: low,
               close: close, volume: volume, amount: amount)
    }

    /// 由收盘价序列生成 K 线：high/low 在收盘价上下浮动 `spread`，open 取前收。
    static func candles(closes: [Double], volume: Double = 1000, spread: Double = 0.03) -> [Candle] {
        var out: [Candle] = []
        var prev = closes.first ?? 0
        for (i, c) in closes.enumerated() {
            out.append(candle(day: i, open: prev, high: c + spread, low: c - spread,
                              close: c, volume: volume))
            prev = c
        }
        return out
    }

    /// 横盘震荡序列：收盘价在 `base` 上下小幅交替，避免 RSI/连涨等退化口径。
    static func sideways(count: Int, base: Double = 10.0, volume: Double = 1000) -> [Candle] {
        (0..<count).map { i in
            let close = base + (i % 2 == 0 ? 0.0 : 0.05)
            return candle(day: i, open: base, high: close + 0.15, low: close - 0.15,
                          close: close, volume: volume)
        }
    }

    static func stockData(candles: [Candle]) -> StockData {
        StockData(security: security, quote: nil, candles: candles,
                  fundFlow: nil, fundFlowHistory: [])
    }

    static func context(candles: [Candle]) -> MarketContext {
        MarketContext.build(from: stockData(candles: candles))
    }

    // MARK: 分时夹具

    static func intradayPoint(minute: Int, price: Double, avg: Double, volume: Double) -> IntradayPoint {
        IntradayPoint(time: date(minutes: minute), price: price, avgPrice: avg,
                      volume: volume, cumVolume: 0, cumAmount: 0)
    }

    /// 由 (价格, 均价, 量) 三元组生成分时数据。dayHigh/dayLow 由点列算出。
    static func intradayData(_ rows: [(price: Double, avg: Double, volume: Double)],
                             prevClose: Double) -> IntradayData {
        let points = rows.enumerated().map { pair in
            intradayPoint(minute: pair.offset, price: pair.element.price,
                          avg: pair.element.avg, volume: pair.element.volume)
        }
        let prices = points.map(\.price)
        return IntradayData(security: security, previousClose: prevClose, points: points,
                            dayHigh: prices.max() ?? 0, dayLow: prices.min() ?? 0,
                            updatedAt: baseDate)
    }

    /// 指定时区的本地时间（用于交易时段测试）。
    static func dateInZone(_ string: String, timeZoneID: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: timeZoneID)
        f.dateFormat = "yyyy-MM-dd HH:mm"
        guard let d = f.date(from: string) else {
            fatalError("测试夹具日期解析失败：\(string)")
        }
        return d
    }
}
