import XCTest
@testable import QuantLens

// MARK: - 支撑压力 / 日线信号 / 回测 / 分级边界

final class LevelsSignalsTests: XCTestCase {

    // MARK: 支撑压力

    func testLevelsDetectRepeatedSwingLow() {
        // 100 根：每 12 根出现一次 9.5 的探底，其余在 10.0 附近震荡
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
        // 默认配置只取最近 3 档支撑 + 3 档压力（展示上限）
        let capped = LevelEngine.detect(candles: candles)
        XCTAssertFalse(capped.isEmpty)
        XCTAssertLessThanOrEqual(capped.count, 6)
        // 全部分数在 0~100，距离符号与方向一致
        for l in capped {
            XCTAssertTrue((0...100).contains(l.score))
            if l.kind == .support { XCTAssertLessThan(l.distancePct, 0) }
            if l.kind == .resistance { XCTAssertGreaterThan(l.distancePct, 0) }
        }

        // 放宽展示上限后，重复探底的摆动低点簇应被检出为支撑（聚类中心允许 5% 偏差）
        let levels = LevelEngine.detect(candles: candles, config: LevelEngine.Config(maxLevels: 10))
        let supports = levels.filter { $0.kind == .support }
        XCTAssertFalse(supports.isEmpty)
        XCTAssertTrue(supports.contains { abs($0.price - 9.35) / 9.35 < 0.05 })
    }

    func testLevelsInsufficientDataReturnsEmpty() {
        XCTAssertTrue(LevelEngine.detect(candles: []).isEmpty)
        XCTAssertTrue(LevelEngine.detect(candles: Fixtures.sideways(count: 10)).isEmpty)
    }

    func testVolumeProfilePointOfControl() {
        // 重量级 K 线集中在 10.0 窄幅区间，轻量 K 线宽幅摊薄：
        // 控制点（最大成交量箱体）应落在 10.0 附近
        var candles: [Candle] = []
        for i in 0..<60 {
            if i % 3 == 0 {
                candles.append(Fixtures.candle(day: i, open: 10.0, high: 10.05, low: 9.95,
                                               close: 10.0, volume: 5000))
            } else {
                candles.append(Fixtures.candle(day: i, open: 10.0, high: 10.5, low: 9.5,
                                               close: 10.0, volume: 100))
            }
        }
        let profile = LevelEngine.volumeProfile(candles: candles, bins: 60)
        XCTAssertNotNil(profile.pointOfControl)
        XCTAssertEqual(profile.pointOfControl ?? 0, 10.0, accuracy: 0.1)
    }

    // MARK: 信号引擎

    func testEvaluateEarlyIndexReturnsZero() {
        let ctx = Fixtures.context(candles: Fixtures.sideways(count: 40))
        let ev = SignalEngine.evaluate(ctx, at: 10)
        XCTAssertEqual(ev.buy.score, 0)
        XCTAssertEqual(ev.risk.score, 0)
        XCTAssertEqual(ev.accumulate.score, 0)
        XCTAssertEqual(ev.distribute.score, 0)
    }

    func testSignalBundleFinalizeClamps() {
        var b = SignalBundle()
        b.add(150, "超大")
        b.finalize()
        XCTAssertEqual(b.score, 100)
        var c = SignalBundle()
        c.subtract(20, "扣过头")
        c.finalize()
        XCTAssertEqual(c.score, 0)
    }

    func testBreakBelowMA20ReasonPresent() {
        // 40 根缓涨后一根放量长阴跌破 MA20：风险理由必须包含跌破均线
        let closes: [Double] = (0..<40).map { 10.0 + Double($0) * 0.045 }
        var candles = Fixtures.candles(closes: closes, spread: 0.1)
        candles.append(Fixtures.candle(day: 40, open: 11.8, high: 11.9, low: 8.9,
                                       close: 9.0, volume: 3000))
        let ctx = Fixtures.context(candles: candles)
        let ev = SignalEngine.evaluate(ctx, at: ctx.lastIndex)
        XCTAssertTrue(ev.risk.reasons.contains { $0.contains("跌破20日均线") })
        XCTAssertGreaterThan(ev.risk.score, 0)
    }

    func testRSIOverboughtReasonPresent() {
        // 持续大步上涨：RSI 冲入超买区，风险理由必须包含 RSI 超买
        let closes = (0..<45).map { 10.0 + Double($0) * 0.3 }
        let ctx = Fixtures.context(candles: Fixtures.candles(closes: closes, spread: 0.05))
        let ev = SignalEngine.evaluate(ctx, at: ctx.lastIndex)
        XCTAssertTrue(ev.risk.reasons.contains { $0.contains("超买") })
    }

    func testAnalyzeInsufficientData() {
        let data = Fixtures.stockData(candles: Fixtures.sideways(count: 30))
        let analysis = SignalEngine.analyze(data: data, period: .day)
        XCTAssertTrue(analysis.signals.isEmpty)
        XCTAssertTrue(analysis.summary.contains("不足"))
    }

    func testAnalyzeSignalsMeetThresholdAndEvalConsistent() {
        var candles = Fixtures.sideways(count: 60)
        candles.append(Fixtures.candle(day: 60, open: 10.0, high: 10.9, low: 10.0,
                                       close: 10.8, volume: 3000))
        let data = Fixtures.stockData(candles: candles)
        let analysis = SignalEngine.analyze(data: data, period: .day)
        for s in analysis.signals {
            XCTAssertGreaterThanOrEqual(s.score, 45)
        }
        let direct = SignalEngine.evaluate(analysis.context, at: analysis.context.lastIndex)
        XCTAssertEqual(analysis.eval.buy.score, direct.buy.score, accuracy: 1e-9)
        XCTAssertEqual(analysis.eval.risk.score, direct.risk.score, accuracy: 1e-9)
    }

    func testBacktestFlatSeriesHasNoSamples() {
        let ctx = Fixtures.context(candles: Fixtures.sideways(count: 80))
        let result = BacktestEngine.run(ctx: ctx, kind: .buy)
        XCTAssertEqual(result.samples, 0)
        XCTAssertEqual(result.winRate, 0)
    }

    // MARK: 分级边界（ScanEngine.grade 纯函数）

    private func grade(_ opportunity: Double, _ rr: Double, _ risk: Double,
                       _ dist: Double = 0, _ down: Bool = false, _ stop: Double = 4) -> ScanGrade {
        ScanEngine.grade(opportunity: opportunity, riskReward: rr, riskScore: risk,
                         distributeScore: dist, isStrongDown: down,
                         stopLossPct: stop, entryLow: 10.0).grade
    }

    func testGradeStrongExitVetoWins() {
        XCTAssertEqual(grade(90, 3.0, 10, 60), .avoid)
        XCTAssertEqual(grade(90, 3.0, 10, 59.9), .strong)
    }

    func testGradeStrongDownVeto() {
        XCTAssertEqual(grade(90, 3.0, 10, 0, true), .avoid)
    }

    func testGradeWideStopVeto() {
        let r = ScanEngine.grade(opportunity: 90, riskReward: 3.0, riskScore: 10,
                                 distributeScore: 0, isStrongDown: false,
                                 stopLossPct: 8.01, entryLow: 10.0)
        XCTAssertEqual(r.grade, .avoid)
        XCTAssertTrue(r.verdict.contains("止损"))
        XCTAssertEqual(grade(90, 3.0, 10, 0, false, 8.0), .strong)
    }

    func testGradeStrongBoundary() {
        XCTAssertEqual(grade(62, 2.0, 59.9), .strong)
        XCTAssertEqual(grade(61.9, 2.0, 10), .buy)
        XCTAssertEqual(grade(62, 1.99, 10), .buy)
        XCTAssertEqual(grade(62, 2.0, 60), .buy)
    }

    func testGradeBuyBoundary() {
        XCTAssertEqual(grade(48, 1.5, 69.9), .buy)
        XCTAssertEqual(grade(47.9, 1.5, 10), .watch)
        XCTAssertEqual(grade(48, 1.49, 10), .watch)
        XCTAssertEqual(grade(48, 1.5, 70), .watch)
    }

    func testGradeWatchAndNone() {
        XCTAssertEqual(grade(34, 1.0, 10), .watch)
        XCTAssertEqual(grade(33.9, 1.0, 10), .none)
        // 低机会分但高风险 -> 观察（不是无机会）
        XCTAssertEqual(grade(10, 1.0, 60), .watch)
        XCTAssertEqual(grade(10, 1.0, 59.9), .none)
    }
}
