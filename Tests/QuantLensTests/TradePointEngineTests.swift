// TradePointEngineTests.swift
// 显式买卖点引擎测试：合成夹具断言每个检测器、融合门控、模板解释器、Ollama 请求构造。

import Foundation
import Testing
@testable import QuantLens

private func makeCandle(day: Int, open: Double, high: Double, low: Double, close: Double, volume: Double) -> Candle {
    Fixtures.candle(day: day, open: open, high: high, low: low, close: close, volume: volume)
}

/// 从收盘价序列生成 K 线（高=收+0.05、低=收-0.05、开=前收）。
private func risingCandles(closes: [Double], volume: Double = 1000) -> [Candle] {
    var out: [Candle] = []
    for (i, c) in closes.enumerated() {
        let open = i == 0 ? c : closes[i - 1]
        out.append(makeCandle(day: i + 1, open: open, high: c + 0.05, low: c - 0.05, close: c, volume: volume))
    }
    return out
}

private func features(for ctx: MarketContext) -> TradePointFeatures {
    TradePointFeatures.build(candles: ctx.candles, closes: ctx.closes, volumes: ctx.volumes)
}

private func makePoint(index: Int, kind: TradePointKind, strength: Double = 60) -> TradePointSignal {
    TradePointSignal(kind: kind, index: index, date: Date(timeIntervalSince1970: Double(index) * 86400),
                     price: 10.0, strength: strength, reason: kind.label, stopLoss: 9.5, target: 10.8, atr: 0.25)
}

struct TradePointEngineTests {

    // MARK: - ADX

    @Test("ADX：稳步上涨序列 ADX 显著高于震荡序列")
    func adxTrendingVsFlat() {
        var trend: [Candle] = []
        for i in 0..<40 {
            let c = 10.0 + 0.05 * Double(i)
            trend.append(makeCandle(day: i + 1, open: c - 0.05, high: c + 0.03, low: c - 0.03, close: c, volume: 1000))
        }
        var flat: [Candle] = []
        for i in 0..<40 {
            let c = i % 2 == 0 ? 10.0 : 10.02
            flat.append(makeCandle(day: i + 1, open: c, high: c + 0.03, low: c - 0.03, close: c, volume: 1000))
        }
        let adxTrend = Indicators.adx(trend)
        let adxFlat = Indicators.adx(flat)
        let lastTrend = adxTrend.last ?? .nan
        let lastFlat = adxFlat.last ?? .nan
        #expect(adxTrend.count == trend.count)
        #expect(lastTrend > 25)
        #expect(lastFlat < 25)
    }

    // MARK: - B1

    @Test("B1：稳步上行 + 创 252 日新高 + 放量打点，止损不超过 7%")
    func trendTemplateBreakout() {
        var closes: [Double] = []
        for i in 0..<259 { closes.append(10.0 + 0.008 * Double(i)) }
        closes.append(12.3)
        var candles = risingCandles(closes: closes)
        // 最后一根放量 3 倍
        let last = candles[candles.count - 1]
        candles[candles.count - 1] = makeCandle(day: 260, open: last.open, high: 12.35, low: 12.2, close: 12.3, volume: 3000)
        let ctx = Fixtures.context(candles: candles)
        let p = TradePointEngine.detectTrendTemplate(ctx: ctx, features: features(for: ctx), at: candles.count - 1)
        #expect(p != nil)
        #expect(p?.kind == .trendTemplateBreakout)
        #expect(p?.direction == .buy)
        #expect(p?.stopLoss ?? 0 >= 12.3 * 0.93)
        #expect(p?.target ?? 0 > 12.3)
    }

    @Test("B1：不放量时不打点")
    func trendTemplateNoVolume() {
        var closes: [Double] = []
        for i in 0..<260 { closes.append(10.0 + 0.008 * Double(i)) }
        let candles = risingCandles(closes: closes)
        let ctx = Fixtures.context(candles: candles)
        let p = TradePointEngine.detectTrendTemplate(ctx: ctx, features: features(for: ctx), at: candles.count - 1)
        #expect(p == nil)
    }

    // MARK: - B2

    @Test("B2：箱体突破 + 放量打点")
    func rangeBreakout() {
        var all: [Candle] = []
        for i in 0..<30 { all.append(makeCandle(day: i + 1, open: 10.0, high: 10.05, low: 9.95, close: 10.0, volume: 1000)) }
        for i in 0..<25 {
            let c = 10.0 + 0.1 * Double(i % 5)
            let vol = i >= 20 ? 500.0 : 1000.0
            all.append(makeCandle(day: 31 + i, open: c, high: c + 0.04, low: c - 0.04, close: c, volume: vol))
        }
        all.append(makeCandle(day: 56, open: 10.5, high: 11.0, low: 10.4, close: 10.9, volume: 2500))
        let ctx = Fixtures.context(candles: all)
        let p = TradePointEngine.detectRangeBreakout(ctx: ctx, at: all.count - 1)
        #expect(p != nil)
        #expect(p?.kind == .rangeBreakout)
    }

    // MARK: - B3

    @Test("B3：均线回踩缩量收回打点")
    func maPullback() {
        var closes: [Double] = []
        for i in 0..<30 { closes.append(10.0 + 0.1 * Double(i)) }
        var candles = risingCandles(closes: closes)
        // 最后一根：低点贴 MA20 收回，缩量收阳
        candles[candles.count - 1] = makeCandle(day: 30, open: 12.3, high: 12.6, low: 11.98, close: 12.5, volume: 700)
        let ctx = Fixtures.context(candles: candles)
        let p = TradePointEngine.detectMAPullback(ctx: ctx, at: candles.count - 1)
        #expect(p != nil)
        #expect(p?.kind == .maPullback)
    }

    // MARK: - B4

    @Test("B4：动量放量 + OBV 新高打点")
    func momentumSurge() {
        var closes: [Double] = []
        for i in 0..<10 { closes.append(10.0 + 0.01 * Double(i)) }
        for i in 0..<10 { closes.append(10.1 + 0.09 * Double(i)) }
        for i in 0..<9 { closes.append(11.0 + 0.02 * Double(i)) }
        closes.append(11.2)
        var candles = risingCandles(closes: closes)
        let last = candles[candles.count - 1]
        candles[candles.count - 1] = makeCandle(day: 30, open: last.open, high: 11.25, low: 11.15, close: 11.2, volume: 2500)
        let ctx = Fixtures.context(candles: candles)
        let p = TradePointEngine.detectMomentumSurge(ctx: ctx, at: candles.count - 1, limitUp: 0.10)
        #expect(p != nil)
        #expect(p?.kind == .momentumSurge)
    }

    // MARK: - B5

    @Test("B5：N 字二波（回踩守 MA20 + 放量破整理高点）打点")
    func secondWave() {
        var candles: [Candle] = []
        // 32 根平盘
        for i in 0..<32 { candles.append(makeCandle(day: i + 1, open: 10.0, high: 10.05, low: 9.95, close: 10.0, volume: 1000)) }
        // 一波：10 根涨到 12.0
        for i in 0..<10 {
            let c = 10.0 + 0.2 * Double(i + 1)
            candles.append(makeCandle(day: 33 + i, open: c - 0.2, high: c + 0.05, low: c - 0.05, close: c, volume: 1000))
        }
        // 回踩：8 根跌到 11.0，缩量
        let pullbacks = [11.7, 11.5, 11.3, 11.2, 11.1, 11.0, 11.05, 11.1]
        for (i, c) in pullbacks.enumerated() {
            candles.append(makeCandle(day: 43 + i, open: c + 0.1, high: c + 0.08, low: c - 0.05, close: c, volume: 600))
        }
        // 二波突破
        candles.append(makeCandle(day: 51, open: 11.2, high: 12.2, low: 11.15, close: 12.1, volume: 2000))
        let ctx = Fixtures.context(candles: candles)
        let p = TradePointEngine.detectSecondWave(ctx: ctx, at: candles.count - 1)
        #expect(p != nil)
        #expect(p?.kind == .secondWave)
    }

    // MARK: - B6

    private func reversalCandles(triggerOpen: Double) -> [Candle] {
        [
            makeCandle(day: 1, open: 10.0, high: 10.1, low: 9.9, close: 10.0, volume: 1000),
            makeCandle(day: 2, open: 10.5, high: 11.0, low: 10.4, close: 11.0, volume: 1500),
            makeCandle(day: 3, open: 11.5, high: 12.1, low: 11.4, close: 12.1, volume: 2000),
            makeCandle(day: 4, open: 12.1, high: 12.2, low: 11.4, close: 11.5, volume: 1200),
            makeCandle(day: 5, open: 11.6, high: 12.7, low: 11.5, close: 12.65, volume: 2500),
            makeCandle(day: 6, open: triggerOpen, high: triggerOpen + 0.3, low: triggerOpen - 0.1, close: triggerOpen + 0.2, volume: 1800),
        ]
    }

    @Test("B6：确认式首阴反包在溢价 ≤5.5% 时触发，触发价为开盘价")
    func confirmedReversalFires() {
        let ctx = Fixtures.context(candles: reversalCandles(triggerOpen: 13.0))
        let p = TradePointEngine.detectConfirmedReversal(ctx: ctx, at: 5, limitUp: 0.10)
        #expect(p != nil)
        #expect(p?.kind == .confirmedReversal)
        #expect(p?.price == 13.0)
        #expect(p?.strength == 60)
        #expect(p?.sizeNote == "最小仓位级别")
    }

    @Test("B6：溢价超过 5.5% 时不触发")
    func confirmedReversalPremiumGate() {
        let ctx = Fixtures.context(candles: reversalCandles(triggerOpen: 13.6))
        let p = TradePointEngine.detectConfirmedReversal(ctx: ctx, at: 5, limitUp: 0.10)
        #expect(p == nil)
    }

    // MARK: - B7

    @Test("B7：震荡市触 BB 下轨 + RSI 超卖收回打点")
    func meanReversion() {
        var candles: [Candle] = []
        // 28 根对称小幅震荡：多空动量平衡，ADX 保持低位
        for i in 0..<28 {
            let c = i % 2 == 0 ? 10.50 : 10.505
            candles.append(makeCandle(day: i + 1, open: c, high: c + 0.02, low: c - 0.02, close: c, volume: 1000))
        }
        // 两根急跌：RSI 跌入超卖、布林带张开
        candles.append(makeCandle(day: 29, open: 10.50, high: 10.52, low: 10.10, close: 10.12, volume: 1000))
        candles.append(makeCandle(day: 30, open: 10.12, high: 10.14, low: 9.98, close: 10.00, volume: 1000))
        // 触下轨收回的阳线（收盘价贴下轨上方，未创 20 日新低）
        candles.append(makeCandle(day: 31, open: 10.09, high: 10.19, low: 10.11, close: 10.15, volume: 1000))
        let ctx = Fixtures.context(candles: candles)
        let p = TradePointEngine.detectMeanReversion(ctx: ctx, features: features(for: ctx), at: candles.count - 1)
        #expect(p != nil)
        #expect(p?.kind == .meanReversion)
    }

    // MARK: - S1 / S3

    @Test("S1：收盘破 MA20 + MA20 拐头向下打点（先跌穿、反弹回 MA20 上方、再新鲜跌破）")
    func trendBreakdown() {
        var candles: [Candle] = []
        // 25 根平盘
        for i in 0..<25 {
            candles.append(makeCandle(day: i + 1, open: 12.0, high: 12.05, low: 11.95, close: 12.0, volume: 1000))
        }
        // 10 根下跌：MA20 拐头向下
        let declines = [11.9, 11.8, 11.7, 11.6, 11.5, 11.4, 11.3, 11.2, 11.1, 11.0]
        for (i, c) in declines.enumerated() {
            candles.append(makeCandle(day: 26 + i, open: c + 0.1, high: c + 0.05, low: c - 0.05, close: c, volume: 1000))
        }
        // 3 根反弹回 MA20 上方
        for (i, c) in [11.5, 11.7, 11.8].enumerated() {
            candles.append(makeCandle(day: 36 + i, open: c - 0.1, high: c + 0.05, low: c - 0.05, close: c, volume: 1000))
        }
        // 新鲜跌破
        candles.append(makeCandle(day: 39, open: 11.7, high: 11.75, low: 11.15, close: 11.2, volume: 1000))
        let ctx = Fixtures.context(candles: candles)
        let p = TradePointEngine.detectTrendBreakdown(ctx: ctx, at: candles.count - 1)
        #expect(p != nil)
        #expect(p?.kind == .trendBreakdown)
        #expect(p?.direction == .sell)
    }

    @Test("S3：新鲜收盘跌破 20 日最低点打点")
    func supportBreak() {
        var candles: [Candle] = []
        for i in 0..<30 {
            candles.append(makeCandle(day: i + 1, open: 10.0, high: 10.1, low: 9.9, close: 10.0, volume: 1000))
        }
        candles.append(makeCandle(day: 31, open: 10.0, high: 10.05, low: 9.75, close: 9.8, volume: 1500))
        let ctx = Fixtures.context(candles: candles)
        let p = TradePointEngine.detectSupportBreak(ctx: ctx, at: candles.count - 1)
        #expect(p != nil)
        #expect(p?.kind == .supportBreak)
        #expect(p?.direction == .sell)
    }

    // MARK: - S2

    @Test("S2：高位滞涨贪婪信号转译为卖点")
    func greedyTopMapping() {
        var closes: [Double] = []
        for i in 0..<130 { closes.append(10.0 + 0.015 * Double(i)) }
        var candles = risingCandles(closes: closes)
        let last = candles[candles.count - 1]
        candles[candles.count - 1] = makeCandle(day: 130, open: last.open, high: 11.99, low: 11.88, close: 11.95, volume: 3000)
        let ctx = Fixtures.context(candles: candles)
        let result = TradePointEngine.evaluateAll(ctx: ctx, from: ctx.count - 5, limitUp: 0.10)
        var hasGreedy = false
        for p in result.points where p.kind == .greedyTop {
            hasGreedy = true
            #expect(p.direction == .sell)
        }
        #expect(hasGreedy)
    }

    // MARK: - 融合与门控

    @Test("融合：同族 5 根内去重、跨 5 根保留")
    func fuseCooldown() {
        let p1 = makePoint(index: 10, kind: .rangeBreakout)
        let p2 = makePoint(index: 13, kind: .rangeBreakout)
        let p3 = makePoint(index: 15, kind: .rangeBreakout)
        let fused = TradePointEngine.fuse([p1, p2, p3], gates: .unknown)
        #expect(fused.count == 2)
        #expect(fused[0].index == 10)
        #expect(fused[1].index == 15)
    }

    @Test("融合：同日 ≥2 族标强，B6 永不标强")
    func fuseConfluence() {
        let p1 = makePoint(index: 20, kind: .rangeBreakout)
        let p2 = makePoint(index: 20, kind: .momentumSurge)
        let p3 = makePoint(index: 21, kind: .confirmedReversal)
        let p4 = makePoint(index: 21, kind: .maPullback)
        let fused = TradePointEngine.fuse([p1, p2, p3, p4], gates: .unknown)
        #expect(fused[0].isStrong)
        #expect(fused[1].isStrong)
        #expect(!fused[2].isStrong)
        #expect(fused[3].isStrong)
    }

    @Test("门控：指数走熊 + 宽度恶化否决买点、卖点不受影响；数据缺失放行")
    func gateVeto() {
        let breadth = MarketBreadth(total: 100, advancing: 20, declining: 80,
                                    limitUp: 5, limitDown: 10, sourceLabel: "测试")
        let gates = TradePointGates(indexTrend: .bearish, breadth: breadth)
        #expect(gates.vetoBuys)
        let buy = makePoint(index: 30, kind: .rangeBreakout)
        let sell = makePoint(index: 30, kind: .supportBreak)
        let fused = TradePointEngine.fuse([buy, sell], gates: gates)
        #expect(fused[0].isVetoed)
        #expect(!fused[0].isStrong)
        #expect(!fused[1].isVetoed)

        let gatesNoBreadth = TradePointGates(indexTrend: .bearish, breadth: nil)
        #expect(!gatesNoBreadth.vetoBuys)
        let fused2 = TradePointEngine.fuse([buy], gates: gatesNoBreadth)
        #expect(!fused2[0].isVetoed)
    }

    @Test("指数趋势：上涨序列看多、下跌序列看空、不足 26 根未知")
    func indexTrend() {
        var up: [Candle] = []
        for i in 0..<40 {
            let c = 3000.0 + 5.0 * Double(i)
            up.append(makeCandle(day: i + 1, open: c - 5, high: c + 2, low: c - 2, close: c, volume: 1000))
        }
        var down: [Candle] = []
        for i in 0..<40 {
            let c = 3200.0 - 5.0 * Double(i)
            down.append(makeCandle(day: i + 1, open: c + 5, high: c + 2, low: c - 2, close: c, volume: 1000))
        }
        #expect(TradePointEngine.indexTrend(from: up) == .bullish)
        #expect(TradePointEngine.indexTrend(from: down) == .bearish)
        #expect(TradePointEngine.indexTrend(from: Array(up.prefix(10))) == .unknown)
    }

    // MARK: - 模板解释器

    @Test("模板解释器：输出包含价格、止损、目标、R 值与失效条件，不编造数字")
    func explainerOutput() {
        let p = makePoint(index: 30, kind: .rangeBreakout, strength: 75)
        let text = SignalExplainer.explain(p)
        #expect(text.contains("10.00"))
        #expect(text.contains("9.50"))
        #expect(text.contains("10.80"))
        #expect(text.contains("平台突破"))
        #expect(text.contains("失效"))
        let inv = SignalExplainer.invalidation(p)
        #expect(inv.contains("9.50"))
    }

    @Test("模板解释器：被否决的点注明环境门控否决")
    func explainerVetoNote() {
        var p = makePoint(index: 30, kind: .rangeBreakout)
        p.isVetoed = true
        p.gateNote = "指数走弱且市场宽度恶化，环境门控否决，仅观察"
        let text = SignalExplainer.explain(p)
        #expect(text.contains("门控否决"))
    }

    // MARK: - Ollama 请求构造与校验（不联网）

    @Test("Ollama 请求体：模型、温度、max_tokens、stream 字段正确，信号数字在 payload 内")
    func llmRequestBody() {
        let cfg = LocalLLMConfig(enabled: true, baseURL: "http://localhost:11434/v1", model: "qwen2.5:3b",
                                 temperature: 0, maxTokens: 250, timeoutSeconds: 20)
        let p = makePoint(index: 30, kind: .rangeBreakout, strength: 75)
        let body = LLMPromptBuilder.requestBody(points: [p], breadth: nil, model: cfg.model, temperature: cfg.temperature, maxTokens: cfg.maxTokens)
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("请求体不可序列化为 JSON")
            return
        }
        #expect(obj["model"] as? String == "qwen2.5:3b")
        #expect(obj["temperature"] as? Double == 0)
        #expect(obj["max_tokens"] as? Int == 250)
        #expect(obj["stream"] as? Bool == false)
        let messages = obj["messages"] as? [[String: Any]] ?? []
        #expect(messages.count == 2)
        let userContent = messages.count == 2 ? (messages[1]["content"] as? String ?? "") : ""
        #expect(userContent.contains("平台突破"))
        #expect(userContent.contains("\"price\":10"))
        #expect(userContent.contains("\"target\":10.8"))
    }

    @Test("LLM 输出校验：引用给定数字通过、编造数字拒绝")
    func llmOutputValidation() {
        let p = makePoint(index: 30, kind: .rangeBreakout, strength: 75)
        let payload = LLMPromptBuilder.userPayload(points: [p], breadth: nil)
        let allowed = LLMOutputValidator.allowedNumbers(fromPayload: payload)
        let good = "信号价格 10.00，止损 9.50，目标 10.80，盈亏比 1.6。"
        let bad = "信号价格 10.00，预计涨到 15.00。"
        #expect(LLMOutputValidator.isConsistent(good, allowedNumbers: allowed))
        #expect(!LLMOutputValidator.isConsistent(bad, allowedNumbers: allowed))
    }

    @Test("LLM 响应解析：合法 JSON 提取 content，非法返回 nil")
    func llmParseContent() {
        let good = """
        {"choices":[{"message":{"content":"解读文字"}}]}
        """.data(using: .utf8) ?? Data()
        #expect(LocalLLMClient.parseContent(good) == "解读文字")
        let bad = "not json".data(using: .utf8) ?? Data()
        #expect(LocalLLMClient.parseContent(bad) == nil)
    }

    // MARK: - TradePoint 转译

    @Test("TradePoint.from：保留止损、目标、R 值与强/否决标记")
    func tradePointConversion() {
        var p = makePoint(index: 30, kind: .rangeBreakout, strength: 75)
        p.isStrong = true
        let tp = TradePoint.from(tradePointSignal: p)
        #expect(tp.stopLoss == 9.5)
        #expect(tp.target == 10.8)
        #expect(tp.isStrong)
        #expect(!tp.isVetoed)
        #expect(tp.rMultiple != nil)
    }
}
