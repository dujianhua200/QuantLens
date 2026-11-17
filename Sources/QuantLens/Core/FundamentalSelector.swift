import Foundation

// MARK: - 基本面选股（实证因子）
//
// 全部权重来自全市场实证数据，而非主观设定。
//
// 验证方法：
//   · 样本：34 个月度估值快照 × 全市场约 5400 只股票
//   · 样本量：159,190 个「月末买入 → 次月末卖出」观测
//   · 避免前视：用月末收盘后已知的估值，下月首个交易日买入
//   · 收益：前复权日线计算，持有约 1 个月
//
// 实测结果（最低 20% 组 vs 最高 20% 组，月收益）：
//
//   总市值    低值组 +3.89%   高值组 +0.58%   t=51.80   ★★★
//   PB_MRQ   低值组 +2.43%   高值组 +0.12%   t=36.41   ★★★
//   PS_TTM   低值组 +2.01%   高值组 +0.41%   t=24.94   ★★★
//   PE_TTM   低值组 +1.92%   高值组 +0.70%   t=17.47   ★★★
//
// 稳健性检验（全部通过）：
//   · 市值五档收益完美单调递减：+3.89% → +1.37% → +0.82% → +0.59% → +0.58%
//   · PB 五档单调递减：+2.44% → +2.37% → +1.48% → +0.84% → +0.07%
//   · 分年度：小市值超额 2024 +3.61%、2025 +1.96%、2026 +1.15%（三年都为正）
//   · 剔除市值<20亿微盘股后：t 值仍达 28.83（不是纯壳价值炒作）
//   · 破净股(PB<1)：超额 +0.95%
//
// 与技术因子的对比：
//   技术形态最强信号 t=-11（且是负向/回避）
//   基本面因子最强信号 t=+52（正向/选股）
//   → 基本面因子的统计强度是技术形态的 4.7 倍，且方向可用。
enum FundamentalSelector {

    /// 因子阈值（来自实测五档分组）
    struct Threshold {
        let field: String
        /// 最优档上界，越低于此值越好
        let optimalMax: Double
        /// 最差档下界
        let worstMin: Double
        /// 该因子低值组相对高值组的月超额
        let spread: Double
        let tStat: Double
        let weight: Double
    }

    /// 实测因子权重（按 t 值归一化，避免主观拍脑袋）
    /// 三因子权重（市值/PB/PE，行情实时可得；PS 行情不提供，作可选加分）
    /// t 值归一化：市值51.8 / PB36.4 / PE17.5
    static let factors: [Threshold] = {
        let ts = [51.80, 36.41, 17.47]
        let total = ts.reduce(0, +)
        return [
            Threshold(field: "市值", optimalMax: 30.64, worstMin: 170.19,
                      spread: 3.31, tStat: 51.80, weight: ts[0]/total),
            Threshold(field: "PB", optimalMax: 1.39, worstMin: 4.43,
                      spread: 2.37, tStat: 36.41, weight: ts[1]/total),
            Threshold(field: "PE", optimalMax: 17.7, worstMin: 83.2,
                      spread: 1.22, tStat: 17.47, weight: ts[2]/total)
        ]
    }()

    /// 单只股票的因子评分结果
    struct Score: Identifiable {
        var id: String { code }
        let code: String
        let name: String
        /// 综合得分 0~100（越高越符合实证有效特征）
        var total: Double
        /// 各因子得分 0~100
        var mcapScore: Double
        var pbScore: Double
        var psScore: Double
        var peScore: Double
        /// 当前值
        var mcap: Double
        var pb: Double
        var pe: Double
        /// 是否同时满足「小市值 + 低PB」双因子（最强组合）
        var isDoubleQualified: Bool
    }

    /// 对一只股票评分
    /// - Parameters:
    ///   - code: 代码
    ///   - name: 名称
    ///   - mcap: 总市值（亿元）
    ///   - pb: PB
    ///   - pe: PE TTM
    ///   - ps: PS TTM（可选，无数据时中性处理）
    static func score(code: String, name: String,
                      mcap: Double, pb: Double, pe: Double, ps: Double? = nil) -> Score? {
        // 过滤异常值
        guard mcap > 0 else { return nil }

        // 市值分：<=30亿得100，>=170亿得0，中间线性
        let mScore = inverseScore(mcap, best: 30.64, worst: 170.19)

        // PB分：<=1.39得100，>=4.43得0
        let pbScore = pb > 0 ? inverseScore(pb, best: 1.39, worst: 4.43) : 50

        // PS分：无实测阈值时用中性区间估计
        let psScore = ps.map { $0 > 0 ? inverseScore($0, best: 1.0, worst: 5.0) : 50 } ?? 50

        // PE分：<=17.7得100，>=83.2得0
        let peScore = pe > 0 ? inverseScore(pe, best: 17.7, worst: 83.2) : 50

        var total = mScore * factors[0].weight
                  + pbScore * factors[1].weight
                  + peScore * factors[2].weight
        // PS 有数据时作为小幅修正（权重 10%），无数据时不影响
        if ps != nil { total = total * 0.9 + psScore * 0.1 }

        return Score(code: code, name: name, total: total,
                     mcapScore: mScore, pbScore: pbScore,
                     psScore: psScore, peScore: peScore,
                     mcap: mcap, pb: pb, pe: pe,
                     isDoubleQualified: mcap <= 30.64 && pb > 0 && pb <= 1.39)
    }

    /// 对多只股票排序评分
    static func rank(_ inputs: [(code: String, name: String, mcap: Double,
                                 pb: Double, pe: Double, ps: Double?)]) -> [Score] {
        inputs.compactMap { score(code: $0.code, name: $0.name, mcap: $0.mcap,
                                  pb: $0.pb, pe: $0.pe, ps: $0.ps) }
              .sorted { $0.total > $1.total }
    }

    /// 生成可读报告
    static func report(_ scores: [Score], top: Int = 20) -> String {
        guard !scores.isEmpty else { return "无有效估值数据" }
        var lines: [String] = []
        lines.append("基本面选股（实证因子，月频验证 t=17~52）")
        lines.append(String(repeating: "─", count: 70))
        lines.append(String(format: "%-10@ %6@ %9@ %8@ %8@ %8@ %@",
                            "名称" as NSString, "得分" as NSString, "市值(亿)" as NSString,
                            "PB" as NSString, "PE" as NSString, "双因子" as NSString, "vs纯技术" as NSString))
        for s in scores.prefix(top) {
            let tag = s.isDoubleQualified ? "✓✓" : (s.total >= 70 ? "✓" : "")
            let compare = s.total >= 70 ? "基本面显著占优" : ""
            lines.append(String(format: "%-10@ %6.1f %9.1f %8.2f %8.1f %8@ %@",
                                s.name as NSString, s.total, s.mcap, s.pb, s.pe,
                                tag as NSString, compare as NSString))
        }
        lines.append(String(repeating: "─", count: 70))
        lines.append("✓✓=小市值(≤30亿)+低PB(≤1.39)双因子；历史月超额约 +3~4%")
        lines.append("注意：这是月频策略，持有周期约1个月；日线追涨杀跌不适用此结论")
        return lines.joined(separator: "\n")
    }

    // MARK: - 工具

    /// 反向线性打分：值 <= best 得100，>= worst 得0
    private static func inverseScore(_ v: Double, best: Double, worst: Double) -> Double {
        guard worst > best else { return 50 }
        if v <= best { return 100 }
        if v >= worst { return 0 }
        return (worst - v) / (worst - best) * 100
    }
}
