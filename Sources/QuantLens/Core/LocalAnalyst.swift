import Foundation

// MARK: - 本地智能分析引擎（零 Key / 零 Token / 离线）

/// 不依赖任何外部 API 的走势研判引擎。
///
/// 设计目标：
/// - **不需要 API Key**，不联网、零 token 消耗；
/// - 输出与 `AIVerdict` 同构的结果，UI 可直接复用；
/// - 给出**可执行的买点/卖点价位**，用于在分时图上标注「买」「卖」。
///
/// 打分依据（全部来自实时行情，确定性计算）：
/// 1. 分时趋势（价格相对均价线、斜率）
/// 2. 量价配合（放量上涨 / 缩量回调 / 放量滞涨）
/// 3. 相对昨收位置（高位/中位/低位）
/// 4. 盘口强弱（委比、内外盘比）
/// 5. 支撑压力（日内高低点、均价线、整数关口）
enum LocalAnalyst {

    /// 分析结果
    struct Verdict {
        /// 强烈买入 / 买入 / 观察 / 回避
        var action: String
        /// 0-100 信心
        var confidence: Int
        /// 建议买入区间
        var buyZone: (low: Double, high: Double)?
        /// 建议卖出/目标区间
        var sellZone: (low: Double, high: Double)?
        /// 止损价
        var stopLoss: Double?
        /// 当前是否适合买入
        var isBuyNow: Bool
        /// 分时图上要标注的买点（价格 + 对应分钟索引）
        var buyMarks: [Mark]
        /// 分时图上要标注的卖点
        var sellMarks: [Mark]
        /// 依据
        var reasons: [String]
        /// 风险
        var risks: [String]
        /// 一句话结论
        var summary: String
        /// 当前交易场景（强势回踩/均价线争夺/等MA20支撑…）
        var scene: String
    }

    struct Mark {
        var price: Double
        /// 分时序列索引（用于定位 X 坐标）
        var index: Int
        var label: String
    }

    // MARK: - 主入口

    /// 综合分析。`intraday` 必填，`book` 可选（有则纳入盘口维度）。
    /// 日线级别的背景约束。分时判断必须服从日线趋势，
    /// 否则「下跌趋势中的日内反弹」会被误判为买点。
    struct DailyBias {
        /// 日线趋势方向
        var trend: TrendDirection = .sideways
        /// 收盘价相对 MA20 的偏离 %
        var vsMA20: Double = 0
        /// 收盘价相对 MA60 的偏离 %
        var vsMA60: Double = 0
        /// MA20 斜率（近 5 日，%）
        var ma20Slope: Double = 0
        /// 是否处于 MA20 下方（空头格局）
        var belowMA20: Bool = false
        /// 是否处于 MA60 下方
        var belowMA60: Bool = false
        /// 近 20 日涨跌 %
        var change20D: Double = 0
        /// 平均真实波幅（占价格 %），用于自适应止损宽度
        var atrPct: Double = 2.0
        /// MA20 / MA60 的具体价位（作为支撑参考）
        var ma20Value: Double = 0
        var ma60Value: Double = 0
        /// 近 20 日最低价（重要支撑）
        var low20D: Double = 0
        /// 近 20 日最高价（重要压力）
        var high20D: Double = 0
        /// 近 5 日均量 / 近 20 日均量（量能趋势）
        var volTrendRatio: Double = 1.0
    }

    static func analyze(intraday: IntradayData,
                        book: OrderBook?,
                        floatCap: Double = 0,
                        daily: DailyBias? = nil) -> Verdict {

        let pts = intraday.points
        let prev = intraday.previousClose
        guard pts.count >= 3, prev > 0 else {
            return emptyVerdict()
        }

        let last = pts[pts.count - 1]
        let lastPrice = last.price
        let changePct = (lastPrice / prev - 1) * 100
        let avgPrice = last.avgPrice

        var score = 50.0          // 中性起点
        var reasons: [String] = []
        var risks: [String] = []

        // ── ① 价格相对均价线（分时强弱的第一判据）
        let aboveAvg = lastPrice >= avgPrice
        let avgGapPct = avgPrice > 0 ? (lastPrice - avgPrice) / avgPrice * 100 : 0
        if aboveAvg {
            score += min(14, 7 + avgGapPct * 3)
            reasons.append(String(format: "价格站在均价线上方 %.2f%%", avgGapPct))
        } else {
            score -= min(16, 7 + abs(avgGapPct) * 3)
            risks.append(String(format: "价格跌破均价线 %.2f%%", abs(avgGapPct)))
        }

        // ── ② 趋势斜率（最近 20 分钟的走势方向）
        let window = min(20, max(3, pts.count - 1))
        let refIdx = pts.count - 1 - window
        let refPrice = pts[refIdx].price
        let slopePct = refPrice > 0 ? (lastPrice - refPrice) / refPrice * 100 : 0
        if slopePct > 0.3 {
            score += min(12, slopePct * 8)
            reasons.append(String(format: "近 %d 分钟上行 %.2f%%", window, slopePct))
        } else if slopePct < -0.3 {
            score -= min(14, abs(slopePct) * 8)
            risks.append(String(format: "近 %d 分钟回落 %.2f%%", window, abs(slopePct)))
        }

        // ── ③ 量价配合（最近 20 分钟量能 vs 全天均量）
        let volWindow = Array(pts.suffix(window))
        let recentVol = volWindow.map(\.volume).reduce(0, +)
        let avgVolPerMin = pts.map(\.volume).reduce(0, +) / Double(max(pts.count, 1))
        let volRatio = avgVolPerMin > 0 ? (recentVol / Double(window)) / avgVolPerMin : 1
        let rising = slopePct > 0
        if volRatio > 1.5 && rising {
            score += 10
            reasons.append(String(format: "放量上行（量能 %.1f 倍）", volRatio))
        } else if volRatio > 1.5 && !rising {
            score -= 10
            risks.append(String(format: "放量下跌（量能 %.1f 倍）", volRatio))
        } else if volRatio < 0.7 && !rising {
            score += 4
            reasons.append("缩量回调，抛压有限")
        } else if volRatio < 0.7 && rising {
            score -= 3
            risks.append("缩量上行，动能不足")
        }

        // ── ④ 日内位置（相对最高最低）
        let hi = intraday.dayHigh, lo = intraday.dayLow
        var dayPos = 0.5
        if hi > lo {
            dayPos = (lastPrice - lo) / (hi - lo)
        }
        if dayPos > 0.8 {
            score += 6
            reasons.append("处于日内高位")
        } else if dayPos < 0.2 {
            score -= 5
            risks.append("处于日内低位，弱势")
        }

        // ── ⑤ 盘口（有数据才用）
        if let b = book, !b.bids.isEmpty, !b.asks.isEmpty {
            let ratio = b.bidAskRatio
            if ratio > 20 {
                score += 7
                reasons.append(String(format: "委比 +%.0f%%，买盘占优", ratio))
            } else if ratio < -20 {
                score -= 7
                risks.append(String(format: "委比 %.0f%%，卖压偏重", ratio))
            }
            // 内外盘
            let totalOI = b.outerVolume + b.innerVolume
            if totalOI > 0 {
                let outRatio = b.outerVolume / totalOI
                if outRatio > 0.55 {
                    score += 5
                    reasons.append(String(format: "外盘占比 %.0f%%，主动买盘积极", outRatio * 100))
                } else if outRatio < 0.45 {
                    score -= 5
                    risks.append(String(format: "内盘占比 %.0f%%，主动卖压", (1 - outRatio) * 100))
                }
            }
        }

        // ── ⑥ 涨跌幅极端修正
        if changePct > 7 {
            score -= 6
            risks.append("涨幅已超 7%，追高风险上升")
        } else if changePct < -5 {
            score -= 6
            risks.append("跌幅超 5%，趋势偏弱")
        } else if changePct > 2 && changePct < 6 {
            score += 5
            reasons.append(String(format: "涨幅 %.1f%%，处于健康区间", changePct))
        }

        // ── ⑦ 日线约束（决定性）：分时再强，逆日线趋势也要降级
        var dailyNotes: [String] = []
        if let dly = daily {
            // 趋势方向
            switch dly.trend {
            case .strongUp:
                score += 10
                dailyNotes.append("日线强势上行")
            case .up:
                score += 5
                dailyNotes.append("日线趋势向上")
            case .sideways:
                score += 0
            case .down:
                score -= 14
                dailyNotes.append("日线趋势向下")
            case .strongDown:
                score -= 22
                dailyNotes.append("日线强势下跌")
            }

            // 均线位置：MA20 是中期多空分界
            if dly.belowMA20 {
                score -= 12
                dailyNotes.append(String(format: "股价在 MA20 下方 %.1f%%", abs(dly.vsMA20)))
            } else if dly.vsMA20 > 3 {
                score += 4
            }

            // MA60 之下属于长期弱势区
            if dly.belowMA60 {
                score -= 8
                dailyNotes.append("股价在 MA60 下方，中期偏弱")
            }

            // MA20 斜率：走平或向下时，日内反弹不可信
            if dly.ma20Slope < -0.5 {
                score -= 8
                dailyNotes.append("MA20 向下倾斜，反弹持续性差")
            } else if dly.ma20Slope > 0.5 {
                score += 4
            }

            // 近 20 日跌幅过大，属于下跌趋势中的反抽
            if dly.change20D < -10 {
                score -= 10
                dailyNotes.append(String(format: "近 20 日累跌 %.1f%%，处于下跌通道", abs(dly.change20D)))
            }

            reasons.append(contentsOf: dailyNotes.filter { !$0.contains("下方") && !$0.contains("向下") && !$0.contains("下跌") && !$0.contains("偏弱") })
            risks.append(contentsOf: dailyNotes.filter { $0.contains("下方") || $0.contains("向下") || $0.contains("下跌") || $0.contains("偏弱") })
        } else {
            risks.append("缺少日线数据，判断仅基于分时")
        }

        score = min(100, max(0, score))

        // ── 硬性否决：日线明确走坏时，不允许给出买入结论
        var vetoed = false
        if let dly = daily {
            if dly.trend == .strongDown || (dly.belowMA20 && dly.belowMA60 && dly.ma20Slope < -0.3) {
                vetoed = true
            }
        }
        if vetoed {
            score = min(score, 44)   // 压到「观察」以下
        }

        let confidence = Int(score.rounded())

        // ── 结论
        let action: String
        let isBuyNow: Bool
        if vetoed {
            action = "回避"
            isBuyNow = false
        } else {
            switch score {
            case 78...:
                action = "强烈买入"; isBuyNow = true
            case 66..<78:
                action = "买入"; isBuyNow = true
            case 50..<66:
                action = "观察"; isBuyNow = false
            default:
                action = "回避"; isBuyNow = false
            }
        }

        // ── 计算买卖价位
        let (buyZone, sellZone, stopLoss, scene) = calcLevels(
            intraday: intraday, last: lastPrice, avg: avgPrice,
            hi: hi, lo: lo, prev: prev, daily: daily
        )

        // ── 生成图上标注点
        let (buyMarks, sellMarks) = findMarks(
            intraday: intraday, buyZone: buyZone, sellZone: sellZone
        )

        let summary = buildSummary(action: action, changePct: changePct,
                                   aboveAvg: aboveAvg, volRatio: volRatio,
                                   buyZone: buyZone, sellZone: sellZone)

        return Verdict(
            action: action, confidence: confidence,
            buyZone: buyZone, sellZone: sellZone, stopLoss: stopLoss,
            isBuyNow: isBuyNow,
            buyMarks: buyMarks, sellMarks: sellMarks,
            reasons: arrayPrefix(reasons, 4), risks: arrayPrefix(risks, 3),
            summary: summary, scene: scene
        )
    }

    // MARK: - 价位计算

    /// 计算买入区间、卖出区间、止损价
    /// 买卖价位计算。核心思路是把短线纪律规则化：
    ///
    /// **买点**：只在有支撑的位置挂单，不做追高。
    ///   - 强势（站上均价）：回踩均价线 / MA5 附近；
    ///   - 中性：回踩日内均价与日内低点之间；
    ///   - 弱势（跌破均价）：必须等跌到日线支撑（MA20/20日低点）才考虑。
    ///
    /// **卖点**：分批止盈，不追求卖在最高。
    ///   - 第一目标：日内高点上方 0.5%（突破前高）
    ///   - 第二目标：昨收 +3.5%（日内常规目标）
    ///   - 压力位：20 日高点（若更近则优先）
    ///
    /// **止损**：用 ATR 自适应，不用固定百分比。
    ///   - 高波动股给宽止损，低波动股给窄止损
    ///   - 同时不低于日内低点太多（避免被日内噪音扫掉）
    private static func calcLevels(
        intraday: IntradayData, last: Double, avg: Double,
        hi: Double, lo: Double, prev: Double, daily: DailyBias?
    ) -> ((Double, Double)?, (Double, Double)?, Double?, String) {

        let atr = daily?.atrPct ?? 2.0
        // 止损宽度：ATR 的 1.2 倍，限制在 1.5%~5%
        let stopWidth = min(5.0, max(1.5, atr * 1.2)) / 100

        var buyLow: Double
        var buyHigh: Double
        var scene: String

        if last > avg * 1.005 {
            // ── 场景 A：强势（明显站上均价线）
            // 打法：等回踩均价线，不追高
            buyHigh = avg * 1.003
            buyLow = avg * 0.997
            scene = "强势回踩"
            // 若均价离现价太远（>4%），说明已跑太远，等 MA5 或日内回撤一半
            if (last - avg) / avg > 0.04 {
                buyHigh = last * 0.975
                buyLow = last * 0.96
                scene = "涨幅过大等回撤"
            }
        } else if last >= avg * 0.995 {
            // ── 场景 B：均价线附近震荡
            // 打法：均价下方轻仓试，跌破就走
            buyHigh = avg * 0.998
            buyLow = avg * (1 - stopWidth * 0.6)
            scene = "均价线争夺"
        } else {
            // ── 场景 C：跌破均价（弱势）
            // 打法：不接下跌的刀，等日线支撑
            if let d = daily, d.ma20Value > 0, d.ma20Value < last {
                // 有 MA20 支撑，在 MA20 上方挂
                buyHigh = d.ma20Value * 1.003
                buyLow = d.ma20Value * 0.995
                scene = "等MA20支撑"
            } else {
                // 无明确支撑：等日内低点上方
                buyHigh = lo * 1.004
                buyLow = lo * 0.996
                scene = "等日内低点"
            }
        }

        // 合理性：买点不得高于现价（高于现价等于追高）
        buyHigh = min(buyHigh, last * 1.001)
        buyLow = min(buyLow, buyHigh)
        if buyLow <= 0 { buyLow = last * (1 - stopWidth) }

        // ── 卖点：分批目标
        let targetA = hi * 1.005                    // 突破日内高点
        let targetB = prev * 1.035                  // 昨收 +3.5%
        var sellLow = min(targetA, targetB)
        var sellHigh = max(targetA, targetB)
        // 20 日高点若在更近处，作为第一目标
        if let d = daily, d.high20D > last * 1.01, d.high20D < sellLow {
            sellLow = d.high20D
        }
        sellLow = max(sellLow, last * 1.006)        // 至少要比现价高，否则无意义
        sellHigh = max(sellHigh, sellLow * 1.012)

        // ── 止损：ATR 自适应，且参考日内低点
        let atrStop = last * (1 - stopWidth)
        let dayLowStop = lo * 0.995
        // 取两者中较高者（更紧的），但若日内低点离现价极近则用 ATR
        var stop = max(atrStop, dayLowStop)
        if (last - stop) / last < 0.008 {
            // 止损太紧容易被扫，放宽到 ATR
            stop = atrStop
        }
        // 止损不高于买入区间下沿
        stop = min(stop, buyLow * 0.998)

        return ((buyLow, buyHigh), (sellLow, sellHigh), stop, scene)
    }

    // MARK: - 标注点定位

    /// 在分时序列里找出触及买入/卖出区间的点，用于画「买」「卖」
    /// 在分时序列里标出真正的买点/卖点。
    ///
    /// 提高准确率的关键：不是「价格碰到区间就标」，而是要求**量价确认**：
    /// - 买点：价格触及买入区间 **且** 该分钟缩量（抛压衰竭）或随后反弹
    /// - 卖点：价格触及卖出区间 **且** 该分钟放量滞涨（冲高乏力）
    ///
    /// 这样标注的是「当时确实该动手的时刻」，而不是事后看的价格带。
    private static func findMarks(
        intraday: IntradayData,
        buyZone: (low: Double, high: Double)?,
        sellZone: (low: Double, high: Double)?
    ) -> ([Mark], [Mark]) {

        var buys: [Mark] = []
        var sells: [Mark] = []
        let pts = intraday.points
        guard pts.count >= 5 else { return ([], []) }

        // 全天均量，用于判断「缩量/放量」
        let avgVol = pts.map(\.volume).reduce(0, +) / Double(pts.count)

        // ── 买点：触及买入区间 + 量能确认
        if let bz = buyZone {
            var lastIdx = -100
            for i in 0..<pts.count {
                let p = pts[i]
                guard p.price >= bz.low, p.price <= bz.high else { continue }
                guard i - lastIdx >= 20 else { continue }   // 至少间隔 20 分钟

                // 量价确认：缩量（< 0.8 倍均量）说明抛压枯竭
                let shrink = avgVol > 0 && p.volume < avgVol * 0.8
                // 或：触及后 3 分钟内反弹（说明有承接）
                var rebound = false
                if i + 3 < pts.count {
                    rebound = pts[i + 3].price > p.price * 1.001
                }

                guard shrink || rebound else { continue }

                buys.append(Mark(price: p.price, index: i, label: "买"))
                lastIdx = i
                if buys.count >= 3 { break }
            }
        }

        // ── 卖点：触及卖出区间 + 放量滞涨
        if let sz = sellZone {
            var lastIdx = -100
            for i in 0..<pts.count {
                let p = pts[i]
                guard p.price >= sz.low, p.price <= sz.high else { continue }
                guard i - lastIdx >= 20 else { continue }

                // 量价确认：放量（> 1.3 倍均量）说明有资金在此出货
                let expand = avgVol > 0 && p.volume > avgVol * 1.3
                // 或：触及后 3 分钟内回落（冲高乏力）
                var fade = false
                if i + 3 < pts.count {
                    fade = pts[i + 3].price < p.price * 0.999
                }

                guard expand || fade else { continue }

                sells.append(Mark(price: p.price, index: i, label: "卖"))
                lastIdx = i
                if sells.count >= 3 { break }
            }
        }

        // 若当前价正处于买入区间且量能配合，标一个「现在可买」
        if let bz = buyZone, let lastPt = pts.last,
           lastPt.price >= bz.low, lastPt.price <= bz.high,
           !buys.contains(where: { $0.index == pts.count - 1 }) {
            buys.append(Mark(price: lastPt.price, index: pts.count - 1, label: "买"))
        }

        return (buys, sells)
    }

    // MARK: - 结论文案

    private static func buildSummary(action: String, changePct: Double,
                                     aboveAvg: Bool, volRatio: Double,
                                     buyZone: (low: Double, high: Double)?,
                                     sellZone: (low: Double, high: Double)?) -> String {
        var s = "现价\(Fmt.pct(changePct, decimals: 2))，"
        s += aboveAvg ? "站上均价线" : "跌破均价线"
        if volRatio > 1.5 { s += "、放量" } else if volRatio < 0.7 { s += "、缩量" }

        switch action {
        case "强烈买入", "买入":
            if let b = buyZone {
                s += String(format: "。回踩 %.2f~%.2f 可分批买入", b.low, b.high)
            }
        case "观察":
            s += "。暂不追高，等待回踩确认"
        default:
            s += "。趋势偏弱，建议观望"
        }
        if let z = sellZone, action != "回避" {
            s += String(format: "；%.2f 上方分批止盈", z.low)
        }
        return s
    }

    private static func emptyVerdict() -> Verdict {
        Verdict(action: "观察", confidence: 50,
                buyZone: nil, sellZone: nil, stopLoss: nil,
                isBuyNow: false, buyMarks: [], sellMarks: [],
                reasons: ["分时数据不足，等待更多数据"],
                risks: [], summary: "数据不足，暂无法判断", scene: "数据不足")
    }

    private static func arrayPrefix<T>(_ a: [T], _ n: Int) -> [T] {
        Array(a.prefix(n))
    }
}
