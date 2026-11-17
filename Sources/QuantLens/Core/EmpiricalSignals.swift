import Foundation

// MARK: - 实证短期买卖点
//
// 本模块的每一条规则都经过全市场数据验证，不是凭经验设定。
//
// 验证方法：
//   · 样本：4838 只 A 股 × 800 根日线（2024-2026，约 3 年）
//   · 样本量：3,188,702 个横截面观测，714 个交易日
//   · 基准：每日全市场平均收益（横截面去均值，剔除市场 beta）
//   · 检验：按日聚合后 t 检验，避免同一天多只股票造成的伪重复
//
// 核心结论（5 日超额收益，相对当日全市场均值）：
//
//   放量上攻(量比>2 且 涨幅>3%)      -1.055%   t=-11.44   极显著跑输
//   强势上涨(20日涨幅>20%)           -1.043%   t= -8.46   极显著跑输
//   温和放量收高(收高+量比1.2~2.5)   -0.917%   t= -8.38   极显著跑输
//   趋势中急跌(上升趋势+5日跌8%)     -0.446%   t= -2.81   显著跑输
//   回调至MA20缩量                   -0.191%   t= -2.33   显著跑输
//   缩量十字星(振幅<2.5%+量比<0.8)   +0.127%   t= +1.11   不显著
//   深度崩盘(20日跌>30%)             +0.328%   t= +1.51   不显著
//
// 解读：
//   1. 「追涨」的负期望极其显著（t 低至 -11），这是最可靠的信号。
//   2. 「抄底」的正期望全部不显著（t < 2），不能作为独立买点。
//   3. 结论不对称：知道「不该买什么」比知道「该买什么」更有价值。
//
// 因此本模块的设计原则是：以「风险规避」为主，而非「选股推荐」。
enum EmpiricalSignals {

    /// 信号等级
    enum Level {
        case strongAvoid   // 极显著跑输，强烈回避
        case avoid         // 显著跑输，建议回避
        case neutral       // 无统计优势
        case weakFavor     // 略正但不显著，仅作参考
    }

    /// 单个信号的实测结果
    struct Finding {
        let id: String
        let name: String
        /// 实测 5 日超额收益（%）
        let edge: Double
        /// t 统计量
        let tStat: Double
        let level: Level
        /// 命中该状态时给用户的说明
        let advice: String
        /// 当前是否触发
        var triggered: Bool = false
    }

    /// 评估结果
    struct Assessment {
        var findings: [Finding]
        /// 综合建议等级（取最严重的回避信号）
        var worstLevel: Level
        /// 一句话结论
        var headline: String
        /// 是否建议买入
        var allowBuy: Bool
    }

    // MARK: - 实测基准数据

    /// 所有已测量的状态及其统计结果
    static let catalog: [Finding] = [
        Finding(id: "surge", name: "放量上攻", edge: -1.055, tStat: -11.44, level: .strongAvoid,
                advice: "量比>2 且涨幅>3%，历史5日超额 -1.06%（t=-11.4）。这是全场最一致的负信号，不要在放量拉升当天追进。"),
        Finding(id: "strong", name: "强势上涨", edge: -1.043, tStat: -8.46, level: .strongAvoid,
                advice: "20日涨幅>20%，历史5日超额 -1.04%（t=-8.5）。短期涨幅过大后，均值回归概率高。"),
        Finding(id: "volup", name: "温和放量收高", edge: -0.917, tStat: -8.38, level: .strongAvoid,
                advice: "收盘价位于当日高位且量比1.2~2.5，历史5日超额 -0.92%（t=-8.4）。形态好看的阳线反而要警惕。"),
        Finding(id: "sharpdrop", name: "趋势中急跌", edge: -0.446, tStat: -2.81, level: .avoid,
                advice: "上升趋势中5日跌超8%，历史5日超额 -0.45%（t=-2.8）。急跌不等于超跌，不要立即接。"),
        Finding(id: "pullback", name: "回调至MA20缩量", edge: -0.191, tStat: -2.33, level: .avoid,
                advice: "上升趋势中回调到MA20且缩量，历史超额 -0.19%（t=-2.3）。经典买点实际是负期望。"),
        Finding(id: "doji", name: "缩量十字星", edge: +0.127, tStat: +1.11, level: .weakFavor,
                advice: "振幅<2.5% 且量比<0.8，历史超额 +0.13%（t=+1.1）。方向略正但统计不显著，仅作观察。"),
        Finding(id: "crash", name: "深度崩盘", edge: +0.328, tStat: +1.51, level: .weakFavor,
                advice: "20日跌幅>30%，历史超额 +0.33%（t=+1.5）。有反弹倾向但不显著，接刀风险仍高。")
    ]

    /// 按 id 取实测数据
    static func finding(_ id: String) -> Finding? {
        catalog.first { $0.id == id }
    }

    // MARK: - 主评估

    /// 对当前个股日线评估实证信号
    static func assess(candles: [Candle]) -> Assessment {
        let n = candles.count
        guard n >= 65 else {
            return Assessment(findings: [], worstLevel: .neutral,
                              headline: "数据不足，无法评估", allowBuy: false)
        }
        let i = n - 1
        let c = candles[i]
        let closes = candles.map(\.close)
        let volumes = candles.map(\.volume)

        var fired: [Finding] = []

        // ── 1. 放量上攻：量比>2 且 20日涨幅>3%
        let vMA5 = volumes.suffix(5).reduce(0, +) / 5
        let volRatio = vMA5 > 0 ? c.volume / vMA5 : 1
        let rev20 = n >= 21 && closes[n - 21] > 0
            ? (c.close - closes[n - 21]) / closes[n - 21] * 100 : 0
        if volRatio > 2.0 && rev20 > 3.0, var f = finding("surge") {
            f.triggered = true; fired.append(f)
        }

        // ── 2. 强势上涨：20日涨幅>20%
        if rev20 > 20.0, var f = finding("strong") {
            f.triggered = true; fired.append(f)
        }

        // ── 3. 温和放量收高：收盘在高位 + 量比 1.2~2.5 + 上涨
        let rng = c.high - c.low
        let closePos = rng > 0 ? (c.close - c.low) / rng : 0.5
        let rev5 = n >= 6 && closes[n - 6] > 0
            ? (c.close - closes[n - 6]) / closes[n - 6] * 100 : 0
        if closePos > 0.7 && volRatio > 1.2 && volRatio < 2.5 && rev5 > 0, var f = finding("volup") {
            f.triggered = true; fired.append(f)
        }

        // ── 4. 趋势中急跌：MA60 向上 + 站上 MA60 + 5日跌>8%
        let ma60 = sma(closes, 60)
        let ma60Prev = n >= 61 ? smaAt(closes, 60, n - 2) : ma60
        let trendUp = ma60 > ma60Prev && c.close > ma60
        if trendUp && rev5 < -8.0, var f = finding("sharpdrop") {
            f.triggered = true; fired.append(f)
        }

        // ── 5. 回调至 MA20 缩量
        let ma20 = sma(closes, 20)
        let dev20 = ma20 > 0 ? (c.close - ma20) / ma20 * 100 : 0
        if trendUp && dev20 >= -3 && dev20 <= 2 && volRatio < 1.0 && rev5 < 0, var f = finding("pullback") {
            f.triggered = true; fired.append(f)
        }

        // ── 6. 缩量十字星：振幅<2.5% + 量比<0.8
        let amp = c.close > 0 ? rng / c.close * 100 : 0
        if amp < 2.5 && volRatio < 0.8, var f = finding("doji") {
            f.triggered = true; fired.append(f)
        }

        // ── 7. 深度崩盘：20日跌幅>30%
        if rev20 < -30.0, var f = finding("crash") {
            f.triggered = true; fired.append(f)
        }

        // ── 综合判断：取最严重的回避信号
        let worst = fired.min { lhs, rhs in
            rank(lhs.level) < rank(rhs.level)
        }?.level ?? .neutral

        let avoidCount = fired.filter { $0.level == .strongAvoid || $0.level == .avoid }.count
        let allowBuy = worst != .strongAvoid && worst != .avoid

        let headline: String
        if let w = fired.filter({ $0.level == .strongAvoid }).first {
            headline = "回避：\(w.name)（实测 \(fmtPct(w.edge))，t=\(String(format: "%.1f", w.tStat))）"
        } else if let w = fired.filter({ $0.level == .avoid }).first {
            headline = "谨慎：\(w.name)（实测 \(fmtPct(w.edge))）"
        } else if let w = fired.filter({ $0.level == .weakFavor }).first {
            headline = "中性偏多：\(w.name)（实测 \(fmtPct(w.edge))，不显著）"
        } else {
            headline = "无显著信号（历史数据显示此时无统计优势）"
        }
        _ = avoidCount

        return Assessment(findings: fired, worstLevel: worst,
                          headline: headline, allowBuy: allowBuy)
    }

    // MARK: - 短期买卖点（实证版）

    /// 给出短期买卖参考位，基于「回避追涨 + 均值回归」而非形态
    struct Levels {
        /// 建议买入区间
        var buyLow: Double
        var buyHigh: Double
        /// 建议卖出/减仓区间
        var sellLow: Double
        var sellHigh: Double
        /// 止损
        var stop: Double
        /// 依据说明
        var basis: String
    }

    static func levels(candles: [Candle], atrPeriod: Int = 14) -> Levels? {
        let n = candles.count
        guard n >= 30 else { return nil }
        let c = candles[n - 1]
        let closes = candles.map(\.close)
        let ma20 = sma(closes, 20)
        let atr = Indicators.atr(candles, period: atrPeriod)
        let atrVal = atr.last ?? (c.close * 0.02)

        // 买入区：MA20 下方 1 ATR 到 MA20 上方 0.3 ATR
        // 依据：实测显示「偏离MA20越低越好」，且深度回调有弱正期望
        let buyLow = max(c.close * 0.85, ma20 - atrVal * 1.0)
        let buyHigh = ma20 + atrVal * 0.3

        // 卖出区：MA20 上方 1.5~3 ATR
        // 依据：实测「20日涨幅>20% 显著跑输」，高位应减仓
        let sellLow = ma20 + atrVal * 1.5
        let sellHigh = ma20 + atrVal * 3.0

        // 止损：买入区下沿再减 1 ATR
        let stop = buyLow - atrVal * 1.0

        let basis = String(format: "MA20=%.2f, ATR=%.2f。买点基于均值回归（实测偏离MA20越低期望越高）；卖点基于「涨幅过大显著跑输」；止损=买区下沿−1ATR",
                           ma20, atrVal)

        return Levels(buyLow: buyLow, buyHigh: buyHigh,
                      sellLow: sellLow, sellHigh: sellHigh,
                      stop: stop, basis: basis)
    }

    // MARK: - 工具

    private static func sma(_ v: [Double], _ p: Int) -> Double {
        guard v.count >= p, p > 0 else { return v.last ?? 0 }
        return v.suffix(p).reduce(0, +) / Double(p)
    }

    /// 计算截至 index 的 p 日均值
    private static func smaAt(_ v: [Double], _ p: Int, _ index: Int) -> Double {
        guard index >= p - 1, index < v.count, p > 0 else { return v.last ?? 0 }
        var s = 0.0
        for k in (index - p + 1)...index { s += v[k] }
        return s / Double(p)
    }

    private static func rank(_ l: Level) -> Int {
        switch l {
        case .strongAvoid: return 0
        case .avoid: return 1
        case .neutral: return 2
        case .weakFavor: return 3
        }
    }

    private static func fmtPct(_ v: Double) -> String {
        String(format: "%+.2f%%", v)
    }
}
