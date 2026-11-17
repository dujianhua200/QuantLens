import Foundation

// MARK: - 竞价打分纯函数

/// 集合竞价新增打分项的纯函数层：不碰网络、不读状态，可单测。
/// `AuctionScanner.evaluate()` 在原有打分（缺口/稳定性/量能/竞价额/市值）之外，
/// 叠加这里的调整项；原有口径不动，调整项全部有界（±12 分以内）。
enum AuctionScoring {

    /// 缺口甜点加成：0.5%~3% 为甜点区（有资金但不透支），给 +4；
    /// 3%~5% 给 +1；其余 0。>5% 的兑现风险由 `cashOutPenalty` 处理。
    static func sweetSpotBonus(gap: Double) -> Double {
        if gap >= 0.5 && gap <= 3.0 { return 4 }
        if gap > 3.0 && gap <= 5.0 { return 1 }
        return 0
    }

    /// 高开兑现风险扣分：>5% 高开且量比不足（<2）时扣 6 分；
    /// >8% 时再扣 4 分（合计 -10）。量能跟上时不扣。
    static func cashOutPenalty(gap: Double, volRatio: Double) -> Double {
        guard gap > 5 else { return 0 }
        guard volRatio < 2 else { return 0 }
        if gap > 8 { return -10 }
        return -6
    }

    /// 委买比加成：委比 = (买量 - 卖量) / (买量 + 卖量) × 100%，取自竞价盘口五档。
    /// ≥30 买盘踊跃 +5；≤-30 卖压沉重 -5；中间线性 0。
    static func bidAskBonus(ratio: Double) -> Double {
        if ratio >= 30 { return 5 }
        if ratio <= -30 { return -5 }
        return 0
    }

    /// 昨日基因加成（来自日 K 历史复核，非竞价盘口字段）。
    /// 昨日涨停 +6；连板 ≥2 再 +4；昨日收盘站当日高位（收盘位置 >0.7）+3。
    /// 返回加分与理由（理由最多 2 条）。
    static func geneBonus(prevLimitUp: Bool, boardStreak: Int,
                          prevCloseStrength: Double) -> (points: Double, reasons: [String]) {
        var points = 0.0
        var reasons: [String] = []
        if prevLimitUp {
            points += 6
            if boardStreak >= 2 {
                points += 4
                reasons.append("昨日涨停，连板 \(boardStreak) 板，短线资金有记忆")
            } else {
                reasons.append("昨日涨停，短线资金有记忆")
            }
        }
        if prevCloseStrength > 0.7 {
            points += 3
            reasons.append("昨日收盘站当日高位，收盘强度好")
        }
        return (points, Array(reasons.prefix(2)))
    }

    /// 情绪周期加成：冰点/退潮期竞价追高风险大，扣 3 分；
    /// 回暖/亢奋期加 3 分；混沌与未知不调整。
    static func emotionBonus(phase: EmotionPhase?) -> Double {
        guard let phase else { return 0 }
        switch phase {
        case .recovery, .euphoria: return 3
        case .ice, .ebb: return -3
        case .chaos: return 0
        }
    }

    /// 竞价分类。panicRepair 由历史复核步骤认定后传入，平时为 false。
    static func classify(gap: Double, stability: Double, volRatio: Double,
                         panicRepair: Bool) -> AuctionClass {
        if panicRepair { return .panicRepair }
        if gap > 5 { return .cashOutRisk }
        if gap >= 0.5 && gap <= 3.0 && stability >= 0.8 && volRatio >= 1.5 {
            return .sweetSpot
        }
        return .normal
    }

    /// 恐慌修复认定：昨日恐慌杀跌（跌超 3%）+ 今日低开（-3%~0.5%）+
    /// 锁定期缺口维持（稳定性 ≥0.75）+ 竞价量比 ≥1.2。
    static func isPanicRepair(gap: Double, stability: Double, volRatio: Double,
                              prevDayChangePct: Double) -> Bool {
        if gap >= 0.5 || gap < -3.0 { return false }
        if prevDayChangePct > -3.0 { return false }
        if stability < 0.75 { return false }
        if volRatio < 1.2 { return false }
        return true
    }

    // MARK: - 历史基因提取

    /// 从日 K 提取昨日基因。昨日 = 最后一根 K 线。
    /// - prevLimitUp：昨日收盘触及涨停价（按 limitUp 幅度，容差 0.1%）
    /// - boardStreak：以昨日为终点的连续涨停天数
    /// - prevDayChangePct：昨日涨跌幅 %
    /// - prevCloseStrength：昨日收盘在当日区间的位置 0~1
    /// K 线不足 3 根时返回全零（historyKnown 由调用方判定）。
    static func gene(from candles: [Candle], limitUp: Double) -> AuctionGene {
        guard candles.count >= 3, limitUp > 0 else {
            return AuctionGene(prevLimitUp: false, boardStreak: 0, prevDayChangePct: 0, prevCloseStrength: 0)
        }
        let last = candles.count - 1
        let yesterday = candles[last]
        let dayBefore = candles[last - 1]
        let prevClose = dayBefore.close
        let limitPrice = prevClose * (1 + limitUp)
        let prevLimitUp = yesterday.close >= limitPrice * 0.999
        let prevDayChangePct = prevClose > 0 ? (yesterday.close - prevClose) / prevClose * 100 : 0
        let prevCloseStrength = yesterday.closePosition

        // 连板：从昨日往前数连续涨停
        var streak = 0
        var idx = last
        while idx >= 1 {
            let c = candles[idx]
            let pc = candles[idx - 1].close
            let lp = pc * (1 + limitUp)
            if c.close >= lp * 0.999 {
                streak += 1
                idx -= 1
            } else {
                break
            }
        }
        return AuctionGene(prevLimitUp: prevLimitUp, boardStreak: streak,
                           prevDayChangePct: prevDayChangePct, prevCloseStrength: prevCloseStrength)
    }
}

/// 昨日历史基因（日 K 口径）。
struct AuctionGene: Hashable {
    var prevLimitUp: Bool
    var boardStreak: Int
    var prevDayChangePct: Double
    var prevCloseStrength: Double
}
