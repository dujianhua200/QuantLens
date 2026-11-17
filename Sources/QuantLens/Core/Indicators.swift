import Foundation

/// 纯 Swift 技术指标库，全部按「与输入等长、前置空值用 NaN 占位」的约定实现，
/// 便于绘图时直接与 K 线下标对齐。
enum Indicators {

    // MARK: - 均线族

    static func sma(_ values: [Double], period: Int) -> [Double] {
        guard period > 0, !values.isEmpty else { return Array(repeating: .nan, count: values.count) }
        var out = Array(repeating: Double.nan, count: values.count)
        var sum = 0.0
        for i in 0..<values.count {
            sum += values[i]
            if i >= period { sum -= values[i - period] }
            if i >= period - 1 { out[i] = sum / Double(period) }
        }
        return out
    }

    static func ema(_ values: [Double], period: Int) -> [Double] {
        guard period > 0, !values.isEmpty else { return Array(repeating: .nan, count: values.count) }
        var out = Array(repeating: Double.nan, count: values.count)
        let k = 2.0 / (Double(period) + 1.0)
        var prev = values[0]
        out[0] = prev
        for i in 1..<values.count {
            prev = values[i] * k + prev * (1 - k)
            out[i] = prev
        }
        return out
    }

    /// 中国券商常用的 SMA(X, N, M) 加权移动平均，用于 KDJ 内部
    static func weightedSMA(_ values: [Double], period: Int, weight: Int = 1) -> [Double] {
        guard period > 0, !values.isEmpty else { return Array(repeating: .nan, count: values.count) }
        var out = Array(repeating: Double.nan, count: values.count)
        var prev = values[0]
        out[0] = prev
        let m = Double(weight)
        let n = Double(period)
        for i in 1..<values.count {
            prev = (values[i] * m + prev * (n - m)) / n
            out[i] = prev
        }
        return out
    }

    static func wma(_ values: [Double], period: Int) -> [Double] {
        guard period > 0, !values.isEmpty else { return Array(repeating: .nan, count: values.count) }
        var out = Array(repeating: Double.nan, count: values.count)
        let denom = Double(period * (period + 1)) / 2.0
        for i in 0..<values.count where i >= period - 1 {
            var acc = 0.0
            for j in 0..<period {
                acc += values[i - j] * Double(period - j)
            }
            out[i] = acc / denom
        }
        return out
    }

    // MARK: - MACD

    struct MACD {
        var dif: [Double]
        var dea: [Double]
        var hist: [Double]
    }

    static func macd(_ closes: [Double], fast: Int = 12, slow: Int = 26, signal: Int = 9) -> MACD {
        let ef = ema(closes, period: fast)
        let es = ema(closes, period: slow)
        var dif = Array(repeating: Double.nan, count: closes.count)
        for i in 0..<closes.count {
            if ef[i].isFinite && es[i].isFinite { dif[i] = ef[i] - es[i] }
        }
        let dea = ema(dif.map { $0.isFinite ? $0 : 0 }, period: signal)
        var hist = Array(repeating: Double.nan, count: closes.count)
        for i in 0..<closes.count {
            if dif[i].isFinite && dea[i].isFinite { hist[i] = (dif[i] - dea[i]) * 2 }
        }
        return MACD(dif: dif, dea: dea, hist: hist)
    }

    // MARK: - RSI

    static func rsi(_ closes: [Double], period: Int = 14) -> [Double] {
        guard closes.count > 1 else { return Array(repeating: .nan, count: closes.count) }
        var out = Array(repeating: Double.nan, count: closes.count)
        var avgGain = 0.0
        var avgLoss = 0.0
        for i in 1..<closes.count {
            let diff = closes[i] - closes[i - 1]
            let gain = max(diff, 0)
            let loss = max(-diff, 0)
            if i <= period {
                avgGain += gain
                avgLoss += loss
                if i == period {
                    avgGain /= Double(period)
                    avgLoss /= Double(period)
                    let rs = avgLoss == 0 ? 100.0 : avgGain / avgLoss
                    out[i] = avgLoss == 0 ? 100 : 100 - 100 / (1 + rs)
                }
            } else {
                avgGain = (avgGain * Double(period - 1) + gain) / Double(period)
                avgLoss = (avgLoss * Double(period - 1) + loss) / Double(period)
                let rs = avgLoss == 0 ? 100.0 : avgGain / avgLoss
                out[i] = avgLoss == 0 ? 100 : 100 - 100 / (1 + rs)
            }
        }
        return out
    }

    // MARK: - KDJ

    struct KDJ {
        var k: [Double]
        var d: [Double]
        var j: [Double]
    }

    static func kdj(_ candles: [Candle], period: Int = 9) -> KDJ {
        let n = candles.count
        guard n > 0 else {
            let empty = [Double]()
            return KDJ(k: empty, d: empty, j: empty)
        }
        var rsv = Array(repeating: Double.nan, count: n)
        for i in 0..<n {
            let start = max(0, i - period + 1)
            var hi = -Double.greatestFiniteMagnitude
            var lo = Double.greatestFiniteMagnitude
            for j in start...i {
                hi = max(hi, candles[j].high)
                lo = min(lo, candles[j].low)
            }
            rsv[i] = hi - lo > 0 ? (candles[i].close - lo) / (hi - lo) * 100 : 50
        }
        let k = weightedSMA(rsv.map { $0.isFinite ? $0 : 50 }, period: 3, weight: 1)
        let d = weightedSMA(k, period: 3, weight: 1)
        var jArr = Array(repeating: Double.nan, count: n)
        for i in 0..<n { jArr[i] = 3 * k[i] - 2 * d[i] }
        return KDJ(k: k, d: d, j: jArr)
    }

    // MARK: - 布林带

    struct Bollinger {
        var upper: [Double]
        var mid: [Double]
        var lower: [Double]
        var bandwidth: [Double]
    }

    static func bollinger(_ closes: [Double], period: Int = 20, mult: Double = 2) -> Bollinger {
        let n = closes.count
        let mid = sma(closes, period: period)
        var upper = Array(repeating: Double.nan, count: n)
        var lower = Array(repeating: Double.nan, count: n)
        var bw = Array(repeating: Double.nan, count: n)
        for i in 0..<n where mid[i].isFinite {
            let start = i - period + 1
            var acc = 0.0
            for j in start...i {
                let d = closes[j] - mid[i]
                acc += d * d
            }
            let sd = sqrt(acc / Double(period))
            upper[i] = mid[i] + mult * sd
            lower[i] = mid[i] - mult * sd
            bw[i] = mid[i] != 0 ? (upper[i] - lower[i]) / mid[i] * 100 : 0
        }
        return Bollinger(upper: upper, mid: mid, lower: lower, bandwidth: bw)
    }

    // MARK: - ATR

    static func trueRange(_ candles: [Candle]) -> [Double] {
        guard !candles.isEmpty else { return [] }
        var tr = Array(repeating: 0.0, count: candles.count)
        tr[0] = candles[0].high - candles[0].low
        for i in 1..<candles.count {
            let c = candles[i]
            let pc = candles[i - 1].close
            tr[i] = max(c.high - c.low, max(abs(c.high - pc), abs(c.low - pc)))
        }
        return tr
    }

    static func atr(_ candles: [Candle], period: Int = 14) -> [Double] {
        let tr = trueRange(candles)
        guard !tr.isEmpty else { return [] }
        var out = Array(repeating: Double.nan, count: tr.count)
        var prev = tr[0]
        out[0] = prev
        for i in 1..<tr.count {
            prev = (prev * Double(period - 1) + tr[i]) / Double(period)
            out[i] = prev
        }
        return out
    }

    // MARK: - OBV / 量能

    static func obv(_ candles: [Candle]) -> [Double] {
        guard !candles.isEmpty else { return [] }
        var out = Array(repeating: 0.0, count: candles.count)
        var acc = 0.0
        for i in 1..<candles.count {
            if candles[i].close > candles[i - 1].close {
                acc += candles[i].volume
            } else if candles[i].close < candles[i - 1].close {
                acc -= candles[i].volume
            }
            out[i] = acc
        }
        return out
    }

    /// 量比：当前量 / 过去 N 根均量
    static func volumeRatio(_ candles: [Candle], period: Int = 20) -> [Double] {
        let vols = candles.map(\.volume)
        let ma = sma(vols, period: period)
        var out = Array(repeating: Double.nan, count: candles.count)
        for i in 0..<candles.count where ma[i].isFinite && ma[i] > 0 {
            out[i] = vols[i] / ma[i]
        }
        return out
    }

    /// 资金流强度代理：用 (收盘-均价)/振幅 * 量 的加权，衡量多空主动方向
    static func moneyFlowMultiplier(_ candles: [Candle]) -> [Double] {
        candles.map { c in
            guard c.range > 0 else { return 0 }
            let mfm = ((c.close - c.low) - (c.high - c.close)) / c.range
            return mfm
        }
    }

    /// CMF (Chaikin Money Flow)
    static func cmf(_ candles: [Candle], period: Int = 20) -> [Double] {
        let mfm = moneyFlowMultiplier(candles)
        var out = Array(repeating: Double.nan, count: candles.count)
        for i in 0..<candles.count where i >= period - 1 {
            var mfv = 0.0
            var vol = 0.0
            for j in (i - period + 1)...i {
                mfv += mfm[j] * candles[j].volume
                vol += candles[j].volume
            }
            out[i] = vol > 0 ? mfv / vol : 0
        }
        return out
    }

    // MARK: - 波动与分位

    /// 收盘价在最近 N 根中的百分位（0~100）
    static func percentileRank(_ closes: [Double], index: Int, lookback: Int) -> Double {
        guard index >= 0, index < closes.count else { return 50 }
        let start = max(0, index - lookback + 1)
        let window = closes[start...index]
        let v = closes[index]
        let below = window.filter { $0 < v }.count
        return window.count > 1 ? Double(below) / Double(window.count - 1) * 100 : 50
    }

    /// 线性回归斜率（对 period 根收盘价），并按价格标准化为「每根涨跌%」
    static func slopePercent(_ closes: [Double], index: Int, period: Int) -> Double {
        guard index >= period - 1, period >= 2 else { return 0 }
        let start = index - period + 1
        let n = Double(period)
        var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0
        for k in 0..<period {
            let x = Double(k)
            let y = closes[start + k]
            sumX += x; sumY += y; sumXY += x * y; sumXX += x * x
        }
        let denom = n * sumXX - sumX * sumX
        guard abs(denom) > 1e-9 else { return 0 }
        let slope = (n * sumXY - sumX * sumY) / denom
        let meanY = sumY / n
        guard meanY != 0 else { return 0 }
        return slope / meanY * 100
    }

    /// 滚动最高/最低
    static func rollingExtremes(_ candles: [Candle], period: Int) -> (high: [Double], low: [Double]) {
        var hi = Array(repeating: Double.nan, count: candles.count)
        var lo = Array(repeating: Double.nan, count: candles.count)
        for i in 0..<candles.count where i >= period - 1 {
            var h = -Double.greatestFiniteMagnitude
            var l = Double.greatestFiniteMagnitude
            for j in (i - period + 1)...i {
                h = max(h, candles[j].high)
                l = min(l, candles[j].low)
            }
            hi[i] = h
            lo[i] = l
        }
        return (hi, lo)
    }

    /// 连续上涨/下跌根数（带符号，正数为连涨）
    static func streak(_ closes: [Double]) -> Int {
        guard closes.count > 1 else { return 0 }
        var count = 0
        let last = closes.count - 1
        let dir = closes[last] >= closes[last - 1] ? 1 : -1
        var i = last
        while i > 0 {
            let cmp = closes[i] >= closes[i - 1] ? 1 : -1
            if cmp != dir { break }
            count += 1
            i -= 1
        }
        return count * dir
    }
}

// MARK: - 数值工具

extension Array where Element == Double {
    /// 最后一个有效值
    var lastFinite: Double? {
        for v in reversed() where v.isFinite { return v }
        return nil
    }

    func value(_ index: Int) -> Double? {
        guard index >= 0, index < count else { return nil }
        let v = self[index]
        return v.isFinite ? v : nil
    }
}
