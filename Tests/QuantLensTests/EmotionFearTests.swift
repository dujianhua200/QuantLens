import XCTest
@testable import QuantLens

// MARK: - 情绪引擎 / 恐惧贪婪信号 / 竞价打分 / 分时新触发

final class EmotionFearTests: XCTestCase {

    // MARK: 情绪相位

    func testEmotionIcePhase() {
        var b = MarketBreadth()
        b.total = 400
        b.advancing = 60
        b.declining = 320
        b.flat = 20
        b.limitUp = 2
        b.limitDown = 30
        b.strongUp = 4
        b.strongDown = 120
        b.changeSum = -800
        b.highKnownCount = 400
        let snap = EmotionEngine.snapshot(breadth: b)
        XCTAssertLessThan(snap.score, 20)
        XCTAssertEqual(snap.phase, .ice)
        XCTAssertGreaterThan(snap.fear, snap.greed)
        XCTAssertTrue(snap.headline.contains("冰点"))
    }

    func testEmotionEuphoriaPhase() {
        var b = MarketBreadth()
        b.total = 400
        b.advancing = 320
        b.declining = 60
        b.flat = 20
        b.limitUp = 40
        b.limitDown = 1
        b.limitUpBroken = 2
        b.strongUp = 100
        b.strongDown = 5
        b.changeSum = 800
        b.highKnownCount = 400
        let snap = EmotionEngine.snapshot(breadth: b)
        XCTAssertGreaterThanOrEqual(snap.score, 60)
        XCTAssertEqual(snap.phase, .euphoria)
        XCTAssertGreaterThan(snap.greed, snap.fear)
    }

    func testEmotionEbbOnHighBreakRate() {
        // 同样亢奋的宽度，但炸板率 38% → 退潮
        var b = MarketBreadth()
        b.total = 400
        b.advancing = 320
        b.declining = 60
        b.flat = 20
        b.limitUp = 40
        b.limitDown = 1
        b.limitUpBroken = 25
        b.strongUp = 100
        b.strongDown = 5
        b.changeSum = 800
        b.highKnownCount = 400
        let snap = EmotionEngine.snapshot(breadth: b)
        XCTAssertEqual(snap.phase, .ebb)
        XCTAssertTrue(snap.headline.contains("炸板率"))
    }

    func testEmotionChaosNeutral() {
        var b = MarketBreadth()
        b.total = 400
        b.advancing = 200
        b.declining = 190
        b.flat = 10
        b.limitUp = 5
        b.limitDown = 4
        b.strongUp = 30
        b.strongDown = 28
        b.changeSum = 40
        b.highKnownCount = 400
        let snap = EmotionEngine.snapshot(breadth: b)
        XCTAssertGreaterThanOrEqual(snap.score, 40)
        XCTAssertLessThan(snap.score, 60)
        XCTAssertEqual(snap.phase, .chaos)
    }

    func testEmotionEmptyBreadth() {
        let snap = EmotionEngine.snapshot(breadth: MarketBreadth())
        XCTAssertEqual(snap.score, 50)
        XCTAssertEqual(snap.phase, .chaos)
        XCTAssertTrue(snap.headline.contains("暂无"))
    }

    func testEmotionBreadthFromQuotes() {
        let sec = { (code: String) in Security(symbol: code, name: "测", market: .sh) }
        func quote(_ code: String, price: Double, high: Double, low: Double) -> Quote {
            Quote(security: sec(code), price: price, prevClose: 10, open: 10, high: high, low: low,
                  volume: 1000, amount: 10000, turnoverRate: 1, pe: 10, pb: 1,
                  totalMarketCap: 100, floatMarketCap: 80, amplitude: 5, timestamp: Fixtures.baseDate)
        }
        // 涨停 1 只、炸板 1 只、跌停 1 只、平盘 1 只
        let quotes = [
            quote("600001", price: 11.0, high: 11.0, low: 10.5),
            quote("600002", price: 10.5, high: 11.0, low: 10.0),
            quote("600003", price: 9.0, high: 9.5, low: 9.0),
            quote("600004", price: 10.0, high: 10.1, low: 9.9)
        ]
        let b = EmotionEngine.breadth(from: quotes)
        XCTAssertEqual(b.total, 4)
        XCTAssertEqual(b.advancing, 2)
        XCTAssertEqual(b.declining, 1)
        XCTAssertEqual(b.flat, 1)
        XCTAssertEqual(b.limitUp, 1)
        XCTAssertEqual(b.limitDown, 1)
        XCTAssertEqual(b.limitUpBroken, 1)
        XCTAssertEqual(b.strongUp, 2)
        XCTAssertEqual(b.strongDown, 1)
        XCTAssertEqual(b.highKnownCount, 4)
        XCTAssertTrue(b.sourceLabel.contains("自选"))
    }

    // MARK: 恐惧 / 贪婪日线信号

    func testPanicCapitulation() {
        var candles = Fixtures.sideways(count: 35)
        candles.append(Fixtures.candle(day: 35, open: 10.0, high: 10.05, low: 9.65, close: 9.7, volume: 3000))
        candles.append(Fixtures.candle(day: 36, open: 9.7, high: 9.75, low: 9.35, close: 9.4, volume: 3000))
        candles.append(Fixtures.candle(day: 37, open: 9.4, high: 9.45, low: 9.05, close: 9.1, volume: 3000))
        candles.append(Fixtures.candle(day: 38, open: 9.0, high: 9.3, low: 8.7, close: 9.25, volume: 2000))
        let ctx = Fixtures.context(candles: candles)
        let signals = FearSignals.evaluate(ctx, at: ctx.lastIndex)
        let hit = signals.first { $0.kind == .panicCapitulation }
        XCTAssertNotNil(hit)
        XCTAssertGreaterThanOrEqual(hit?.score ?? 0, 70)
        XCTAssertEqual(hit?.direction, .buy)
        XCTAssertEqual(hit?.sentiment, .fear)
        XCTAssertTrue(hit?.reason.contains("恐慌") ?? false)
    }

    func testFakeBreakdown() {
        // 复用摆动低点夹具形态：每 12 根一次 9.35 探底，形成有效支撑簇
        var candles: [Candle] = []
        for i in 0..<100 {
            if i % 12 == 6 {
                candles.append(Fixtures.candle(day: i, open: 9.6, high: 9.7, low: 9.35, close: 9.5))
            } else {
                let close = 10.0 + 0.05 * Double(i % 3)
                candles.append(Fixtures.candle(day: i, open: 10.0, high: close + 0.15,
                                               low: close - 0.15, close: close))
            }
        }
        // 当日：盘中跌破支撑至 9.20 后收回 9.62，缩量
        candles.append(Fixtures.candle(day: 100, open: 9.6, high: 9.7, low: 9.20, close: 9.62, volume: 600))
        let ctx = Fixtures.context(candles: candles)
        let signals = FearSignals.evaluate(ctx, at: ctx.lastIndex)
        let hit = signals.first { $0.kind == .fakeBreakdown }
        XCTAssertNotNil(hit)
        XCTAssertTrue(hit?.reason.contains("假破位") ?? false)
    }

    func testIceFirstYang() {
        let closes: [Double] = (0..<40).map { 12.0 - Double($0) * 0.075 }
        var candles = Fixtures.candles(closes: closes, spread: 0.03)
        candles.append(Fixtures.candle(day: 40, open: 9.0, high: 9.45, low: 8.95, close: 9.4, volume: 3000))
        let ctx = Fixtures.context(candles: candles)
        let signals = FearSignals.evaluate(ctx, at: ctx.lastIndex)
        let hit = signals.first { $0.kind == .iceFirstYang }
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.sentiment, .fear)
    }

    func testFearExhaustion() {
        let closes: [Double] = (0..<40).map { 10.5 - Double($0) * 0.03 }
        var candles = Fixtures.candles(closes: closes, spread: 0.03)
        candles.append(Fixtures.candle(day: 40, open: 9.35, high: 9.4, low: 9.30, close: 9.32, volume: 800))
        candles.append(Fixtures.candle(day: 41, open: 9.32, high: 9.35, low: 9.20, close: 9.22, volume: 600))
        candles.append(Fixtures.candle(day: 42, open: 9.20, high: 9.30, low: 9.10, close: 9.25, volume: 400))
        let ctx = Fixtures.context(candles: candles)
        let signals = FearSignals.evaluate(ctx, at: ctx.lastIndex)
        let hit = signals.first { $0.kind == .fearExhaustion }
        XCTAssertNotNil(hit)
        XCTAssertTrue(hit?.reason.contains("衰竭") ?? false)
    }

    func testHighStall() {
        let closes: [Double] = (0..<40).map { 8.0 + Double($0) * 0.075 }
        var candles = Fixtures.candles(closes: closes, spread: 0.03)
        candles.append(Fixtures.candle(day: 40, open: 11.0, high: 11.3, low: 10.9, close: 11.05, volume: 3000))
        let ctx = Fixtures.context(candles: candles)
        let signals = FearSignals.evaluate(ctx, at: ctx.lastIndex)
        let hit = signals.first { $0.kind == .highStall }
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.direction, .sell)
        XCTAssertEqual(hit?.sentiment, .greed)
    }

    func testBlowoffTop() {
        var candles = Fixtures.candles(closes: Array(repeating: 10.0, count: 37), spread: 0.03)
        candles.append(Fixtures.candle(day: 37, open: 10.0, high: 10.35, low: 9.98, close: 10.3, volume: 1500))
        candles.append(Fixtures.candle(day: 38, open: 10.3, high: 10.85, low: 10.28, close: 10.8, volume: 2200))
        candles.append(Fixtures.candle(day: 39, open: 10.8, high: 11.6, low: 10.78, close: 11.56, volume: 4000))
        let ctx = Fixtures.context(candles: candles)
        let signals = FearSignals.evaluate(ctx, at: ctx.lastIndex)
        let hit = signals.first { $0.kind == .blowoffTop }
        XCTAssertNotNil(hit)
        XCTAssertTrue(hit?.reason.contains("赶顶") ?? false)
    }

    func testLimitUpOpenHuge() {
        var candles = Fixtures.candles(closes: Array(repeating: 10.0, count: 40), spread: 0.03)
        candles.append(Fixtures.candle(day: 40, open: 10.5, high: 11.0, low: 10.4, close: 10.55, volume: 4500))
        let ctx = Fixtures.context(candles: candles)
        let signals = FearSignals.evaluate(ctx, at: ctx.lastIndex, limitUp: 0.10)
        let hit = signals.first { $0.kind == .limitUpOpenHuge }
        XCTAssertNotNil(hit)
        // 无涨跌停市场不触发
        let noLimit = FearSignals.evaluate(ctx, at: ctx.lastIndex, limitUp: 0)
        XCTAssertNil(noLimit.first { $0.kind == .limitUpOpenHuge })
    }

    func testFearSignalsEarlyIndexEmpty() {
        let ctx = Fixtures.context(candles: Fixtures.sideways(count: 40))
        XCTAssertTrue(FearSignals.evaluate(ctx, at: 10).isEmpty)
    }

    // MARK: 竞价打分纯函数

    func testAuctionScoringHelpers() {
        XCTAssertEqual(AuctionScoring.sweetSpotBonus(gap: 2.0), 4)
        XCTAssertEqual(AuctionScoring.sweetSpotBonus(gap: 0.6), 4)
        XCTAssertEqual(AuctionScoring.sweetSpotBonus(gap: 4.0), 1)
        XCTAssertEqual(AuctionScoring.sweetSpotBonus(gap: 6.0), 0)

        XCTAssertEqual(AuctionScoring.cashOutPenalty(gap: 6.0, volRatio: 1.0), -6)
        XCTAssertEqual(AuctionScoring.cashOutPenalty(gap: 9.0, volRatio: 1.0), -10)
        XCTAssertEqual(AuctionScoring.cashOutPenalty(gap: 6.0, volRatio: 3.0), 0)
        XCTAssertEqual(AuctionScoring.cashOutPenalty(gap: 4.0, volRatio: 1.0), 0)

        XCTAssertEqual(AuctionScoring.bidAskBonus(ratio: 40), 5)
        XCTAssertEqual(AuctionScoring.bidAskBonus(ratio: -40), -5)
        XCTAssertEqual(AuctionScoring.bidAskBonus(ratio: 0), 0)

        XCTAssertEqual(AuctionScoring.emotionBonus(phase: .recovery), 3)
        XCTAssertEqual(AuctionScoring.emotionBonus(phase: .euphoria), 3)
        XCTAssertEqual(AuctionScoring.emotionBonus(phase: .ice), -3)
        XCTAssertEqual(AuctionScoring.emotionBonus(phase: .ebb), -3)
        XCTAssertEqual(AuctionScoring.emotionBonus(phase: .chaos), 0)
        XCTAssertEqual(AuctionScoring.emotionBonus(phase: nil), 0)

        let gene = AuctionScoring.geneBonus(prevLimitUp: true, boardStreak: 3, prevCloseStrength: 0.8)
        XCTAssertGreaterThanOrEqual(gene.points, 10)
        XCTAssertTrue(gene.reasons.contains { $0.contains("连板") })

        XCTAssertEqual(AuctionScoring.classify(gap: 2.0, stability: 0.9, volRatio: 2.0, panicRepair: false), .sweetSpot)
        XCTAssertEqual(AuctionScoring.classify(gap: 6.0, stability: 0.9, volRatio: 2.0, panicRepair: false), .cashOutRisk)
        XCTAssertEqual(AuctionScoring.classify(gap: -1.0, stability: 0.9, volRatio: 2.0, panicRepair: true), .panicRepair)
        XCTAssertEqual(AuctionScoring.classify(gap: 1.0, stability: 0.5, volRatio: 1.0, panicRepair: false), .normal)

        XCTAssertTrue(AuctionScoring.isPanicRepair(gap: -1.0, stability: 0.8, volRatio: 1.5, prevDayChangePct: -4.0))
        XCTAssertFalse(AuctionScoring.isPanicRepair(gap: 1.0, stability: 0.8, volRatio: 1.5, prevDayChangePct: -4.0))
        XCTAssertFalse(AuctionScoring.isPanicRepair(gap: -1.0, stability: 0.5, volRatio: 1.5, prevDayChangePct: -4.0))
        XCTAssertFalse(AuctionScoring.isPanicRepair(gap: -1.0, stability: 0.8, volRatio: 1.5, prevDayChangePct: -1.0))
    }

    func testAuctionGeneExtraction() {
        let candles = [
            Fixtures.candle(day: 0, open: 9.0, high: 9.05, low: 8.95, close: 9.0),
            Fixtures.candle(day: 1, open: 9.0, high: 9.05, low: 8.95, close: 9.0),
            Fixtures.candle(day: 2, open: 9.2, high: 9.95, low: 9.1, close: 9.9),
            Fixtures.candle(day: 3, open: 10.5, high: 10.95, low: 10.4, close: 10.89)
        ]
        let gene = AuctionScoring.gene(from: candles, limitUp: 0.10)
        XCTAssertTrue(gene.prevLimitUp)
        XCTAssertEqual(gene.boardStreak, 2)
        XCTAssertEqual(gene.prevDayChangePct, 10.0, accuracy: 0.01)
        XCTAssertGreaterThan(gene.prevCloseStrength, 0.7)

        // K 线不足返回全零
        let short = AuctionScoring.gene(from: Array(candles.prefix(2)), limitUp: 0.10)
        XCTAssertFalse(short.prevLimitUp)
        XCTAssertEqual(short.boardStreak, 0)
    }

    // MARK: 分时新触发

    func testPanicVReversal() {
        var rows: [(price: Double, avg: Double, volume: Double)] = []
        rows += Array(repeating: (10.00, 10.00, 100), count: 21)
        rows += [(9.92, 10.00, 80), (9.86, 10.00, 70), (9.82, 10.00, 60),
                 (9.95, 10.00, 100), (10.01, 10.00, 120)]
        let data = Fixtures.intradayData(rows, prevClose: 10.00)
        let triggers = IntradaySignals.evaluate(intraday: data)
        XCTAssertEqual(triggers.count, 1)
        XCTAssertEqual(triggers[0].kind, .panicVReversal)
        XCTAssertEqual(triggers[0].direction, .buy)
        XCTAssertEqual(triggers[0].sentiment, .fear)
        XCTAssertGreaterThanOrEqual(triggers[0].strength, 70)
    }

    func testSecondDipHigher() {
        var rows: [(price: Double, avg: Double, volume: Double)] = []
        rows += Array(repeating: (10.00, 10.00, 100), count: 10)
        rows += [(9.96, 10.00, 90), (9.94, 10.00, 80), (9.96, 10.00, 90)]
        rows += Array(repeating: (10.02, 10.00, 100), count: 4)
        rows += [(9.97, 10.00, 70), (9.96, 10.00, 60), (9.98, 10.00, 80)]
        rows += [(10.01, 10.00, 100), (10.02, 10.00, 100), (10.03, 10.00, 100),
                 (10.03, 10.00, 100), (10.04, 10.00, 100)]
        let data = Fixtures.intradayData(rows, prevClose: 10.00)
        let triggers = IntradaySignals.evaluate(intraday: data)
        let hit = triggers.first { $0.kind == .secondDipHigher }
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.sentiment, .fear)
        XCTAssertTrue(hit?.reason.contains("抬高") ?? false)
    }

    func testAvgLineBreakout() {
        var rows: [(price: Double, avg: Double, volume: Double)] = []
        rows += Array(repeating: (10.00, 10.00, 100), count: 15)
        rows += [(10.01, 10.00, 150), (10.02, 10.00, 160), (10.03, 10.00, 170),
                 (10.04, 10.00, 180), (10.05, 10.00, 200)]
        let data = Fixtures.intradayData(rows, prevClose: 10.00)
        let triggers = IntradaySignals.evaluate(intraday: data)
        XCTAssertEqual(triggers.count, 1)
        XCTAssertEqual(triggers[0].kind, .avgLineBreakout)
        XCTAssertEqual(triggers[0].direction, .buy)
    }

    func testVolumePriceAccel() {
        var rows: [(price: Double, avg: Double, volume: Double)] = []
        rows.append((10.30, 10.00, 80))  // 早盘高点，避免被判为新高突破
        rows += Array(repeating: (10.00, 10.00, 80), count: 14)
        rows += [(10.02, 10.00, 160), (10.03, 10.00, 165), (10.04, 10.00, 170),
                 (10.05, 10.00, 170), (10.06, 10.00, 175)]
        rows += [(10.08, 10.00, 220), (10.10, 10.00, 225), (10.12, 10.00, 230),
                 (10.14, 10.00, 235), (10.16, 10.00, 240)]
        rows += [(10.17, 10.00, 300), (10.18, 10.00, 300), (10.18, 10.00, 300),
                 (10.19, 10.00, 300), (10.19, 10.00, 300)]
        let data = Fixtures.intradayData(rows, prevClose: 10.00)
        let triggers = IntradaySignals.evaluate(intraday: data)
        XCTAssertEqual(triggers.count, 1)
        XCTAssertEqual(triggers[0].kind, .volumePriceAccel)
        XCTAssertEqual(triggers[0].sentiment, .greed)
    }

    func testLateRush() {
        // 时间点落在 14:45 之后：baseDate 为 22:13 UTC，+495 分钟 = 次日 06:28 UTC = 14:28 CST，
        // 最后一个点 minute 524 = 14:57 CST，处于尾盘窗口
        var points: [IntradayPoint] = []
        var rows: [(price: Double, avg: Double, volume: Double)] = []
        rows += Array(repeating: (10.00, 10.00, 100), count: 15)
        rows += [(10.02, 10.00, 150), (10.03, 10.00, 150), (10.04, 10.00, 150),
                 (10.05, 10.00, 150), (10.06, 10.00, 150)]
        rows += [(10.08, 10.00, 250), (10.10, 10.00, 250), (10.11, 10.00, 250),
                 (10.12, 10.00, 250), (10.13, 10.00, 250)]
        rows += [(10.14, 10.00, 320), (10.15, 10.00, 320), (10.16, 10.00, 320),
                 (10.17, 10.00, 320), (10.18, 10.00, 320)]
        for (i, r) in rows.enumerated() {
            points.append(Fixtures.intradayPoint(minute: 495 + i, price: r.price, avg: r.avg, volume: r.volume))
        }
        let prices = points.map(\.price)
        let data = IntradayData(security: Fixtures.security, previousClose: 10.00, points: points,
                                dayHigh: prices.max() ?? 0, dayLow: prices.min() ?? 0,
                                updatedAt: Fixtures.baseDate)
        let triggers = IntradaySignals.evaluate(intraday: data)
        let hit = triggers.first { $0.kind == .lateRush }
        XCTAssertNotNil(hit)
        XCTAssertTrue(hit?.reason.contains("追高") ?? false)
        XCTAssertEqual(hit?.sentiment, .greed)
    }
}
