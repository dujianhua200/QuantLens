import Foundation

/// 信号历史表现回测：验证某类信号出现后，未来 N 日收益分布。
/// 这是判断「提示是否可信」的唯一客观手段，也用于给信号评分做校准。
enum BacktestEngine {

    struct Config {
        var horizons: [Int] = [1, 3, 5, 10]
        var threshold: Double = 48
        var cooldown: Int = 4
        var maxSamples: Int = 1400
    }

    static func run(ctx: MarketContext, kind: SignalKind, config: Config = Config()) -> BacktestResult {
        var samples: [(idx: Int, score: Double)] = []
        var lastIdx = -999
        let start = max(40, ctx.count - config.maxSamples)
        for i in start..<ctx.count {
            let s = SignalEngine.evaluate(ctx, at: i).bundle(for: kind).score
            if s >= config.threshold, i - lastIdx >= config.cooldown {
                samples.append((i, s))
                lastIdx = i
            }
        }

        guard !samples.isEmpty else {
            return BacktestResult(kind: kind, samples: 0, winRate: 0, avgReturn: [:], bestTrade: 0, worstTrade: 0)
        }

        var wins = 0
        var total = 0
        var sums: [Int: Double] = [:]
        var counts: [Int: Int] = [:]
        var allReturns: [Double] = []

        for s in samples {
            for h in config.horizons where s.idx + h < ctx.count {
                let entry = ctx.candles[s.idx].close
                let exit = ctx.candles[s.idx + h].close
                guard entry > 0 else { continue }
                let ret = (exit / entry - 1) * 100
                sums[h, default: 0] += ret
                counts[h, default: 0] += 1
                if h == config.horizons[config.horizons.count / 2] {
                    allReturns.append(ret)
                    total += 1
                    // 买入信号以正收益为赢；风险/撤退信号以负收益为「正确」
                    let correct = (kind == .buy || kind == .accumulate) ? ret > 0 : ret < 0
                    if correct { wins += 1 }
                }
            }
        }

        var avg: [Int: Double] = [:]
        for (h, sum) in sums {
            if let c = counts[h], c > 0 { avg[h] = sum / Double(c) }
        }

        return BacktestResult(
            kind: kind,
            samples: samples.count,
            winRate: total > 0 ? Double(wins) / Double(total) : 0,
            avgReturn: avg,
            bestTrade: allReturns.max() ?? 0,
            worstTrade: allReturns.min() ?? 0
        )
    }

    static func runAll(ctx: MarketContext) -> [BacktestResult] {
        SignalKind.allCases.map { run(ctx: ctx, kind: $0) }
    }
}
