import XCTest
@testable import QuantLens

// MARK: - 分时触发引擎 / 日内支撑 / 交易时段 / 买卖点记录

final class IntradaySignalsTests: XCTestCase {

    // MARK: 分时触发

    func testDipToAverageTrigger() {
        // 前 20 分钟横在均价线上，随后跌破均价至 9.97（浅破 0.3%）又收回 10.05
        var rows: [(price: Double, avg: Double, volume: Double)] = []
        rows += Array(repeating: (10.00, 10.00, 100), count: 20)
        rows += [(9.98, 10.00, 80), (9.97, 10.00, 70), (9.97, 10.00, 70),
                 (9.99, 10.00, 90), (10.01, 10.00, 100)]
        rows += [(10.02, 10.00, 100), (10.03, 10.00, 100), (10.04, 10.00, 100),
                 (10.04, 10.00, 100), (10.05, 10.00, 100)]
        let data = Fixtures.intradayData(rows, prevClose: 10.00)

        let triggers = IntradaySignals.evaluate(intraday: data)
        XCTAssertEqual(triggers.count, 1)
        let t = triggers[0]
        XCTAssertEqual(t.kind, .dipToAverage)
        XCTAssertEqual(t.direction, .buy)
        XCTAssertEqual(t.price, 10.05, accuracy: 1e-9)
        // 踩点缩量（70 < 均量 97 × 0.8）加成 8 分：65 + 8
        XCTAssertEqual(t.strength, 73, accuracy: 0.01)
        XCTAssertTrue(t.reason.contains("回踩均价线"))
    }

    func testBreakoutHighTrigger() {
        // 20 分钟横盘后放量（300 vs 均量 140）连创新高至 10.20
        var rows: [(price: Double, avg: Double, volume: Double)] = []
        rows += Array(repeating: (10.00, 10.00, 100), count: 20)
        rows += [(10.05, 10.00, 300), (10.08, 10.00, 300), (10.12, 10.00, 300),
                 (10.15, 10.00, 300), (10.20, 10.00, 300)]
        let data = Fixtures.intradayData(rows, prevClose: 10.00)

        let triggers = IntradaySignals.evaluate(intraday: data)
        // 突破 + 量比异动同时成立，按强度降序，突破在前
        XCTAssertEqual(triggers.count, 2)
        XCTAssertEqual(triggers[0].kind, .breakoutHigh)
        XCTAssertEqual(triggers[0].direction, .buy)
        XCTAssertGreaterThanOrEqual(triggers[0].strength, triggers[1].strength)
        XCTAssertTrue(triggers[0].reason.contains("突破日内高点"))
        XCTAssertEqual(triggers[1].kind, .volumeSurge)
    }

    func testVolumeSurgeWithoutBreakout() {
        // 早盘高点 10.50，之后回落横盘，尾段放量拉升至 10.30（未创新高）。
        // 均价线全程低于价格，排除“回踩”触发，只测放量上攻。
        var rows: [(price: Double, avg: Double, volume: Double)] = []
        rows += Array(repeating: (10.50, 9.95, 100), count: 5)
        rows += Array(repeating: (10.00, 9.95, 100), count: 15)
        rows += [(10.10, 9.95, 300), (10.15, 9.95, 300), (10.20, 9.95, 300),
                 (10.25, 9.95, 300), (10.30, 9.95, 300)]
        let data = Fixtures.intradayData(rows, prevClose: 10.00)

        let triggers = IntradaySignals.evaluate(intraday: data)
        XCTAssertEqual(triggers.count, 1)
        XCTAssertEqual(triggers[0].kind, .volumeSurge)
        XCTAssertEqual(triggers[0].direction, .buy)
        XCTAssertTrue(triggers[0].reason.contains("放量上攻"))
    }

    func testBelowAverageWeakTrigger() {
        // 价格从均价线一路阴跌至 9.80，全程量能平平（排除跌破新低的量比条件）
        var rows: [(price: Double, avg: Double, volume: Double)] = []
        rows += Array(repeating: (10.00, 10.00, 100), count: 10)
        for i in 10..<30 {
            rows.append((10.00 - 0.01 * Double(i - 9), 10.00, 100))
        }
        let data = Fixtures.intradayData(rows, prevClose: 10.00)

        let triggers = IntradaySignals.evaluate(intraday: data)
        XCTAssertEqual(triggers.count, 1)
        XCTAssertEqual(triggers[0].kind, .belowAverageWeak)
        XCTAssertEqual(triggers[0].direction, .sell)
    }

    func testStalledHighTrigger() {
        // 日内高位 94% 分位横盘，尾段放量但 10 分钟几乎没涨
        var rows: [(price: Double, avg: Double, volume: Double)] = []
        rows += Array(repeating: (10.00, 10.40, 100), count: 5)
        rows += Array(repeating: (10.50, 10.40, 100), count: 5)
        rows += Array(repeating: (10.46, 10.40, 100), count: 15)
        rows += Array(repeating: (10.47, 10.40, 300), count: 5)
        let data = Fixtures.intradayData(rows, prevClose: 10.00)

        let triggers = IntradaySignals.evaluate(intraday: data)
        XCTAssertEqual(triggers.count, 1)
        XCTAssertEqual(triggers[0].kind, .stalledHigh)
        XCTAssertEqual(triggers[0].direction, .sell)
    }

    func testBreakdownLowTrigger() {
        // 横盘后放量连创新低至 9.75（均价线下不足 8 根，排除弱势触发）
        var rows: [(price: Double, avg: Double, volume: Double)] = []
        rows += Array(repeating: (10.00, 10.00, 100), count: 20)
        rows += [(9.95, 10.00, 250), (9.90, 10.00, 250), (9.85, 10.00, 250),
                 (9.80, 10.00, 250), (9.75, 10.00, 250)]
        let data = Fixtures.intradayData(rows, prevClose: 10.00)

        let triggers = IntradaySignals.evaluate(intraday: data)
        XCTAssertEqual(triggers.count, 1)
        XCTAssertEqual(triggers[0].kind, .breakdownLow)
        XCTAssertEqual(triggers[0].direction, .sell)
    }

    func testDegradedInputsReturnNoTriggers() {
        // 点数不足
        let short = Fixtures.intradayData(Array(repeating: (10.0, 10.0, 100.0), count: 5),
                                          prevClose: 10.0)
        XCTAssertTrue(IntradaySignals.evaluate(intraday: short).isEmpty)

        // 空序列
        let empty = Fixtures.intradayData([], prevClose: 10.0)
        XCTAssertTrue(IntradaySignals.evaluate(intraday: empty).isEmpty)

        // 昨收缺失
        let noPrev = Fixtures.intradayData(Array(repeating: (10.0, 10.0, 100.0), count: 20),
                                           prevClose: 0)
        XCTAssertTrue(IntradaySignals.evaluate(intraday: noPrev).isEmpty)

        // 均价线缺失
        let noAvg = Fixtures.intradayData(Array(repeating: (10.0, 0.0, 100.0), count: 20),
                                          prevClose: 10.0)
        XCTAssertTrue(IntradaySignals.evaluate(intraday: noAvg).isEmpty)

        // 平稳横盘：无任何触发
        let flat = Fixtures.intradayData(Array(repeating: (10.0, 10.0, 100.0), count: 30),
                                         prevClose: 10.0)
        XCTAssertTrue(IntradaySignals.evaluate(intraday: flat).isEmpty)
    }

    // MARK: 日内支撑压力

    private func levelsData(lastPrice: Double, lastAvg: Double) -> IntradayData {
        var points: [IntradayPoint] = []
        for i in 0..<15 {
            points.append(Fixtures.intradayPoint(minute: i, price: 10.10, avg: 10.10, volume: 100))
        }
        points.append(Fixtures.intradayPoint(minute: 15, price: lastPrice, avg: lastAvg, volume: 100))
        return IntradayData(security: Fixtures.security, previousClose: 10.00, points: points,
                            dayHigh: 10.50, dayLow: 9.80, updatedAt: Fixtures.baseDate)
    }

    func testIntradayLevelsAboveAverage() {
        // 现价 10.20 在均价线上方：支撑取最高的 10.10（均价线），压力取最低的 10.40（日线压力）
        let levels = IntradayLevels.compute(intraday: levelsData(lastPrice: 10.20, lastAvg: 10.10),
                                            dailySupport: 9.90, dailyResistance: 10.40)
        XCTAssertEqual(levels.support ?? 0, 10.10, accuracy: 1e-9)
        XCTAssertEqual(levels.supportSource, "均价线")
        XCTAssertEqual(levels.distanceToSupportPct ?? 0, 0.9804, accuracy: 0.01)
        XCTAssertEqual(levels.resistance ?? 0, 10.40, accuracy: 1e-9)
        XCTAssertEqual(levels.resistanceSource, "日线压力")
        XCTAssertEqual(levels.distanceToResistancePct ?? 0, 1.9608, accuracy: 0.01)
    }

    func testIntradayLevelsBelowAverage() {
        // 现价 10.05 在均价线下方：均价线转为压力，支撑取昨日收盘 10.00
        let levels = IntradayLevels.compute(intraday: levelsData(lastPrice: 10.05, lastAvg: 10.10),
                                            dailySupport: 9.90, dailyResistance: 10.40)
        XCTAssertEqual(levels.support ?? 0, 10.00, accuracy: 1e-9)
        XCTAssertEqual(levels.supportSource, "昨日收盘")
        XCTAssertEqual(levels.resistance ?? 0, 10.10, accuracy: 1e-9)
        XCTAssertEqual(levels.resistanceSource, "均价线")
    }

    func testIntradayLevelsEmpty() {
        let empty = IntradayData(security: Fixtures.security, previousClose: 10.00, points: [],
                                 dayHigh: 0, dayLow: 0, updatedAt: Fixtures.baseDate)
        let levels = IntradayLevels.compute(intraday: empty, dailySupport: nil, dailyResistance: nil)
        XCTAssertNil(levels.support)
        XCTAssertNil(levels.resistance)
    }

    // MARK: 交易时段（2026-11-17 为周二，11-15 为周日，11-14 为周六）

    func testTradingHoursAStock() {
        let zone = "Asia/Shanghai"
        XCTAssertTrue(TradingHours.isTrading(market: .sh, at: Fixtures.dateInZone("2026-11-17 10:00", timeZoneID: zone)))
        XCTAssertTrue(TradingHours.isTrading(market: .sh, at: Fixtures.dateInZone("2026-11-17 09:30", timeZoneID: zone)))
        XCTAssertTrue(TradingHours.isTrading(market: .sh, at: Fixtures.dateInZone("2026-11-17 11:29", timeZoneID: zone)))
        XCTAssertFalse(TradingHours.isTrading(market: .sh, at: Fixtures.dateInZone("2026-11-17 11:30", timeZoneID: zone)))
        XCTAssertFalse(TradingHours.isTrading(market: .sh, at: Fixtures.dateInZone("2026-11-17 12:00", timeZoneID: zone)))
        XCTAssertFalse(TradingHours.isTrading(market: .sh, at: Fixtures.dateInZone("2026-11-17 09:15", timeZoneID: zone)))
        XCTAssertTrue(TradingHours.isTrading(market: .sh, at: Fixtures.dateInZone("2026-11-17 13:00", timeZoneID: zone)))
        XCTAssertTrue(TradingHours.isTrading(market: .sh, at: Fixtures.dateInZone("2026-11-17 14:59", timeZoneID: zone)))
        XCTAssertFalse(TradingHours.isTrading(market: .sh, at: Fixtures.dateInZone("2026-11-17 15:00", timeZoneID: zone)))
        XCTAssertFalse(TradingHours.isTrading(market: .sz, at: Fixtures.dateInZone("2026-11-15 10:00", timeZoneID: zone)))
        XCTAssertFalse(TradingHours.isTrading(market: .bj, at: Fixtures.dateInZone("2026-11-14 10:00", timeZoneID: zone)))
        XCTAssertTrue(TradingHours.isTrading(market: .index, at: Fixtures.dateInZone("2026-11-17 10:00", timeZoneID: zone)))
        XCTAssertTrue(TradingHours.isAStockTrading(at: Fixtures.dateInZone("2026-11-17 10:00", timeZoneID: zone)))
    }

    func testTradingHoursHKAndUS() {
        XCTAssertTrue(TradingHours.isTrading(market: .hk, at: Fixtures.dateInZone("2026-11-17 11:45", timeZoneID: "Asia/Shanghai")))
        XCTAssertFalse(TradingHours.isTrading(market: .hk, at: Fixtures.dateInZone("2026-11-17 12:30", timeZoneID: "Asia/Shanghai")))
        XCTAssertTrue(TradingHours.isTrading(market: .hk, at: Fixtures.dateInZone("2026-11-17 15:30", timeZoneID: "Asia/Shanghai")))

        let ny = "America/New_York"
        XCTAssertTrue(TradingHours.isTrading(market: .us, at: Fixtures.dateInZone("2026-11-16 10:00", timeZoneID: ny)))
        XCTAssertFalse(TradingHours.isTrading(market: .us, at: Fixtures.dateInZone("2026-11-16 09:00", timeZoneID: ny)))
        XCTAssertFalse(TradingHours.isTrading(market: .us, at: Fixtures.dateInZone("2026-11-16 16:00", timeZoneID: ny)))
        XCTAssertFalse(TradingHours.isTrading(market: .us, at: Fixtures.dateInZone("2026-11-15 10:00", timeZoneID: ny)))
    }

    // MARK: 买卖点记录

    func testTradePointFromSignalDirection() {
        let buy = TradingSignal(kind: .buy, score: 70, title: "t", reasons: ["放量突破"],
                                price: 10.5, date: Fixtures.baseDate, period: .day)
        let bp = TradePoint.from(signal: buy)
        XCTAssertEqual(bp.direction, .buy)
        XCTAssertEqual(bp.kindLabel, "买入机会")
        XCTAssertEqual(bp.source, .daily)
        XCTAssertEqual(bp.reason, "放量突破")

        let dist = TradingSignal(kind: .distribute, score: 80, title: "t", reasons: ["资金流出"],
                                 price: 10.5, date: Fixtures.baseDate, period: .day)
        XCTAssertEqual(TradePoint.from(signal: dist).direction, .sell)

        let acc = TradingSignal(kind: .accumulate, score: 60, title: "t", reasons: [],
                                price: 10.5, date: Fixtures.baseDate, period: .day)
        let ap = TradePoint.from(signal: acc)
        XCTAssertEqual(ap.direction, .buy)
        XCTAssertEqual(ap.reason, "t")  // 无理由时退回标题
    }

    func testTradePointFromTrigger() {
        let trigger = IntradayTrigger(kind: .dipToAverage, direction: .buy, price: 10.05,
                                      time: Fixtures.baseDate, index: 5, strength: 73,
                                      reason: "回踩均价线不破")
        let p = TradePoint.from(trigger: trigger)
        XCTAssertEqual(p.direction, .buy)
        XCTAssertEqual(p.kindLabel, "回踩均价")
        XCTAssertEqual(p.source, .intraday)
        XCTAssertEqual(p.score, 73)
    }

    func testDailyPointsDedupesMarkerOverSignal() {
        let ctx = Fixtures.context(candles: Fixtures.sideways(count: 20))
        let d1 = Fixtures.date(days: 10)
        let d0 = Fixtures.date(days: 5)
        let signal = TradingSignal(kind: .buy, score: 60, title: "s", reasons: ["信号"],
                                   price: 10, date: d1, period: .day)
        let marker = TradingSignal(kind: .buy, score: 75, title: "m", reasons: ["标记"],
                                   price: 10, date: d1, period: .day)
        let old = TradingSignal(kind: .risk, score: 70, title: "o", reasons: ["旧"],
                                price: 10, date: d0, period: .day)
        let analysis = Analysis(context: ctx, signals: [signal], markers: [marker, old],
                                summary: "", eval: BarEvaluation())
        let points = TradePoint.dailyPoints(from: analysis)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].score, 75)  // 同类同时刻只保留标记
        XCTAssertEqual(points[0].date, d1)
        XCTAssertEqual(points[1].date, d0)
        XCTAssertEqual(points[1].direction, .sell)
    }

    func testDailyPointsLimitAndOrder() {
        let ctx = Fixtures.context(candles: Fixtures.sideways(count: 20))
        let markers = (0..<8).map { i in
            TradingSignal(kind: .buy, score: 70, title: "m", reasons: ["r"],
                          price: 10, date: Fixtures.date(days: i), period: .day)
        }
        let analysis = Analysis(context: ctx, signals: [], markers: markers,
                                summary: "", eval: BarEvaluation())
        let points = TradePoint.dailyPoints(from: analysis)
        XCTAssertEqual(points.count, 6)
        XCTAssertEqual(points[0].date, Fixtures.date(days: 7))
        XCTAssertEqual(points[5].date, Fixtures.date(days: 2))
    }

    // MARK: 榜单条目

    func testBuyPointEntryIdentityAndFreshness() {
        let trigger = IntradayTrigger(kind: .dipToAverage, direction: .buy, price: 10.05,
                                      time: Date(), index: 5, strength: 73, reason: "r")
        var entry = BuyPointEntry(security: Fixtures.security, price: 10.05, changePct: 0.5,
                                  trigger: trigger, firstSeenAt: Date(), support: 10.0,
                                  resistance: 10.4, distanceToSupportPct: 0.5,
                                  dailyGrade: .buy, opportunityScore: 55)
        XCTAssertEqual(entry.id, "sh.600519|dipToAverage")
        XCTAssertTrue(entry.isNew)
        entry.firstSeenAt = Date().addingTimeInterval(-601)
        XCTAssertFalse(entry.isNew)
    }
}
