import XCTest
@testable import QuantLens

// MARK: - 指标手算值 spot check

final class IndicatorsTests: XCTestCase {

    func testSMAHandComputed() {
        let out = Indicators.sma([1, 2, 3, 4, 5], period: 3)
        XCTAssertTrue(out[0].isNaN)
        XCTAssertTrue(out[1].isNaN)
        XCTAssertEqual(out[2], 2, accuracy: 1e-9)
        XCTAssertEqual(out[3], 3, accuracy: 1e-9)
        XCTAssertEqual(out[4], 4, accuracy: 1e-9)
    }

    func testSMAEmptyAndBadPeriod() {
        XCTAssertEqual(Indicators.sma([], period: 3), [])
        XCTAssertTrue(Indicators.sma([1, 2], period: 0).allSatisfy(\.isNaN))
    }

    func testEMAHandComputed() {
        // period 3 -> k = 0.5；out[0] 取首值，之后指数递推
        let out = Indicators.ema([10, 12, 14], period: 3)
        XCTAssertEqual(out[0], 10, accuracy: 1e-9)
        XCTAssertEqual(out[1], 11, accuracy: 1e-9)
        XCTAssertEqual(out[2], 12.5, accuracy: 1e-9)
    }

    func testMACDConstantSeriesIsZero() {
        let m = Indicators.macd(Array(repeating: 10.0, count: 30))
        XCTAssertEqual(m.dif.last ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(m.dea.last ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(m.hist.last ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(m.dif.count, 30)
    }

    func testRSIAllUpIs100AllDownIs0() {
        let up = (1...15).map(Double.init)
        let rsiUp = Indicators.rsi(up, period: 14)
        XCTAssertEqual(rsiUp[14], 100, accuracy: 1e-9)

        let down = (1...15).reversed().map(Double.init)
        let rsiDown = Indicators.rsi(down, period: 14)
        XCTAssertEqual(rsiDown[14], 0, accuracy: 1e-9)
    }

    func testKDJMidRangeIs50() {
        // 每根 high=10, low=0, close=5 -> RSV 恒为 50，K/D/J 均为 50
        let candles = (0..<9).map {
            Fixtures.candle(day: $0, open: 5, high: 10, low: 0, close: 5)
        }
        let kdj = Indicators.kdj(candles)
        XCTAssertEqual(kdj.k[8], 50, accuracy: 1e-9)
        XCTAssertEqual(kdj.d[8], 50, accuracy: 1e-9)
        XCTAssertEqual(kdj.j[8], 50, accuracy: 1e-9)
    }

    func testBollingerConstantSeries() {
        let b = Indicators.bollinger(Array(repeating: 10.0, count: 25), period: 20, mult: 2)
        XCTAssertEqual(b.mid[24], 10, accuracy: 1e-9)
        XCTAssertEqual(b.upper[24], 10, accuracy: 1e-9)
        XCTAssertEqual(b.lower[24], 10, accuracy: 1e-9)
        XCTAssertEqual(b.bandwidth[24], 0, accuracy: 1e-9)
        XCTAssertTrue(b.mid[0].isNaN)
    }

    func testATRConstantRange() {
        // 每根振幅恒为 2，真实波幅恒为 2，ATR 收敛于 2
        let candles = (0..<20).map {
            Fixtures.candle(day: $0, open: 11, high: 12, low: 10, close: 11)
        }
        let atr = Indicators.atr(candles, period: 14)
        XCTAssertEqual(atr[19], 2, accuracy: 1e-9)
    }

    func testOBVMonotonicRise() {
        let candles = Fixtures.candles(closes: (1...10).map(Double.init), volume: 100, spread: 0)
        let obv = Indicators.obv(candles)
        XCTAssertEqual(obv[9], 900, accuracy: 1e-9)
        XCTAssertEqual(obv[0], 0, accuracy: 1e-9)
    }

    func testVolumeRatioConstantVolumeIsOne() {
        let candles = Fixtures.candles(closes: Array(repeating: 10.0, count: 10), volume: 100)
        let vr = Indicators.volumeRatio(candles, period: 5)
        XCTAssertEqual(vr[9], 1, accuracy: 1e-9)
    }

    func testCMFAllAtHighIsOne() {
        // 每根收在最高价，资金流量乘数恒为 1，CMF 为 1
        let candles = (0..<10).map {
            Fixtures.candle(day: $0, open: 9, high: 10, low: 9, close: 10, volume: 100)
        }
        let cmf = Indicators.cmf(candles, period: 5)
        XCTAssertEqual(cmf[9], 1, accuracy: 1e-9)
    }

    func testPercentileRankAndSlope() {
        let closes = [1.0, 2, 3, 4, 5]
        XCTAssertEqual(Indicators.percentileRank(closes, index: 4, lookback: 5), 100, accuracy: 1e-9)
        XCTAssertEqual(Indicators.percentileRank(closes, index: 0, lookback: 5), 50, accuracy: 1e-9)
        // 等差序列斜率 1，均值 12 -> 每根 +8.333%
        XCTAssertEqual(Indicators.slopePercent([10, 11, 12, 13, 14], index: 4, period: 5),
                       100.0 / 12.0, accuracy: 0.01)
    }

    func testStreak() {
        XCTAssertEqual(Indicators.streak([1, 2, 3, 4]), 3)
        XCTAssertEqual(Indicators.streak([1, 2, 3, 2]), -1)
        XCTAssertEqual(Indicators.streak([5]), 0)
    }

    func testArrayLastFiniteHelper() {
        let values: [Double] = [.nan, 3, .nan]
        XCTAssertEqual(values.lastFinite, 3)
        XCTAssertNil(values.value(0))
        XCTAssertEqual(values.value(1), 3)
        XCTAssertNil(values.value(99))
    }
}
