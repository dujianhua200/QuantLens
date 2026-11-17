import Foundation

// MARK: - 战法回测（用真实历史数据验证胜率）

/// 对每个战法逐根 K 线回放，统计信号出现后的真实表现。
///
/// 目的：把「凭感觉定的规则」变成「有数据支撑的规则」。
/// 只有跑过回测，才知道哪个战法真有效、该给多少权重。
enum StrategyBacktest {

    /// 单个战法的统计结果
    struct Stat: Identifiable {
        let id: String
        var name: String
        /// 信号出现次数
        var signalCount: Int = 0
        /// 1 日后上涨次数
        var win1D: Int = 0
        /// 3 日后上涨次数
        var win3D: Int = 0
        /// 5 日后上涨次数
        var win5D: Int = 0
        /// 平均 1/3/5 日收益 %
        var avgRet1D: Double = 0
        var avgRet3D: Double = 0
        var avgRet5D: Double = 0
        /// 最大单次盈利 / 亏损 %
        var maxGain: Double = 0
        var maxLoss: Double = 0

        var winRate5D: Double {
            signalCount > 0 ? Double(win5D) / Double(signalCount) * 100 : 0
        }

        /// 期望值：胜率×平均盈利 - 败率×平均亏损
        var expectancy: Double {
            guard signalCount > 0 else { return 0 }
            return avgRet5D
        }
    }

    /// 回测配置
    struct Config {
        /// 持有期（交易日）
        var horizons: [Int] = [1, 3, 5]
        /// 信号间隔，避免连续重复计数
        var minGap: Int = 5
    }

    /// 全市场实测基准（797只×约650日，2024-2026）
    /// 结论来源：按日聚合+去聚集+t检验，避免信号聚集偏差
    struct Verified {
        let id: String
        let name: String
        /// 按日去聚集后的超额收益（相对市场基准）
        let edge: Double
        /// t 值，|t|<1.96 视为不显著
        let tStat: Double
        let verdict: String
    }

    static let verified: [String: Verified] = [
        "diverge":  Verified(id:"diverge",  name:"MACD背离",  edge:-0.245, tStat:-2.86, verdict:"显著跑输"),
        "tail":     Verified(id:"tail",     name:"尾盘异动",  edge:-0.341, tStat:-2.02, verdict:"显著跑输"),
        "squeeze":  Verified(id:"squeeze",  name:"五线粘合",  edge:-0.132, tStat:-0.51, verdict:"不显著"),
        "pullback": Verified(id:"pullback", name:"涨停回马枪", edge:+0.010, tStat:+0.03, verdict:"不显著"),
        "washout":  Verified(id:"washout",  name:"洗盘终结",  edge:-0.569, tStat:-0.59, verdict:"不显著(样本少)")
    ]

    /// 市场基准：全市场5日平均收益
    static let marketBaseline5D: Double = 0.379

    // MARK: - 主入口

    /// 对单只股票的历史 K 线回测所有战法
    static func run(candles: [Candle], config: Config = Config()) -> [Stat] {
        let n = candles.count
        guard n >= 160 else { return [] }

        // 预热期：前 130 根用于形态识别，从 130 开始出信号
        let startIdx = 130
        guard n > startIdx + 6 else { return [] }

        var stats: [String: Stat] = [:]
        var lastSignalIdx: [String: Int] = [:]

        for i in startIdx..<(n - 6) {
            let slice = Array(candles[0...i])
            let result = StrategySignals.evaluate(candles: slice)

            for m in result.matches where m.hit {
                // 间隔控制：同一战法 5 日内不重复计入
                if let last = lastSignalIdx[m.id], i - last < config.minGap { continue }
                lastSignalIdx[m.id] = i

                var st = stats[m.id] ?? Stat(id: m.id, name: m.name)
                st.signalCount += 1

                let entry = candles[i].close
                guard entry > 0 else { continue }

                // 统计各持有期
                for h in config.horizons where i + h < n {
                    let exit = candles[i + h].close
                    let ret = (exit - entry) / entry * 100
                    switch h {
                    case 1:
                        if ret > 0 { st.win1D += 1 }
                        st.avgRet1D += ret
                    case 3:
                        if ret > 0 { st.win3D += 1 }
                        st.avgRet3D += ret
                    case 5:
                        if ret > 0 { st.win5D += 1 }
                        st.avgRet5D += ret
                        st.maxGain = max(st.maxGain, ret)
                        st.maxLoss = min(st.maxLoss, ret)
                    default: break
                    }
                }
                stats[m.id] = st
            }
        }

        // 归一化平均收益
        for (k, var st) in stats where st.signalCount > 0 {
            let c = Double(st.signalCount)
            st.avgRet1D /= c
            st.avgRet3D /= c
            st.avgRet5D /= c
            stats[k] = st
        }

        return stats.values.sorted { $0.signalCount > $1.signalCount }
    }

    /// 对多只股票汇总，得到更稳健的统计
    static func runAggregate(all: [[Candle]], config: Config = Config()) -> [Stat] {
        var merged: [String: Stat] = [:]

        for candles in all {
            for st in run(candles: candles, config: config) {
                var m = merged[st.id] ?? Stat(id: st.id, name: st.name)
                let prevCount = m.signalCount
                m.signalCount += st.signalCount
                m.win1D += st.win1D
                m.win3D += st.win3D
                m.win5D += st.win5D
                // 加权平均
                if m.signalCount > 0 {
                    let newCount = Double(st.signalCount)
                    let total = Double(m.signalCount)
                    m.avgRet1D = (m.avgRet1D * Double(prevCount) + st.avgRet1D * newCount) / total
                    m.avgRet3D = (m.avgRet3D * Double(prevCount) + st.avgRet3D * newCount) / total
                    m.avgRet5D = (m.avgRet5D * Double(prevCount) + st.avgRet5D * newCount) / total
                }
                m.maxGain = max(m.maxGain, st.maxGain)
                m.maxLoss = min(m.maxLoss, st.maxLoss)
                merged[st.id] = m
            }
        }

        return merged.values.sorted { $0.winRate5D > $1.winRate5D }
    }

    /// 生成可读报告
    static func report(_ stats: [Stat]) -> String {
        guard !stats.isEmpty else { return "无回测数据（历史数据不足或未命中战法）" }

        var lines: [String] = []
        lines.append("战法回测报告（按5日胜率排序）")
        lines.append(String(repeating: "─", count: 62))
        lines.append(String(format: "%-12@ %5@ %7@ %8@ %8@ %8@",
                            "战法" as NSString, "信号" as NSString, "5日胜率" as NSString,
                            "1日均" as NSString, "3日均" as NSString, "5日均" as NSString))

        for s in stats {
            lines.append(String(format: "%-12@ %5d %6.1f%% %+7.2f%% %+7.2f%% %+7.2f%%",
                                s.name as NSString, s.signalCount, s.winRate5D,
                                s.avgRet1D, s.avgRet3D, s.avgRet5D))
        }
        lines.append(String(repeating: "─", count: 62))
        return lines.joined(separator: "\n")
    }
}
