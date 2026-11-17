// CloudLLMPacketTests.swift
// 云端模型接入与分析包测试：请求构造、预设、Keychain 接口、分析包格式。全部确定性，不联网。

import Foundation
import Testing
@testable import QuantLens

private func packetPoint(day: Int, kind: TradePointKind, price: Double = 10.20,
                         stopLoss: Double = 9.80, target: Double = 11.00,
                         strength: Double = 62) -> TradePointSignal {
    TradePointSignal(kind: kind, index: day, date: Fixtures.date(days: day),
                     price: price, strength: strength, reason: kind.label + "触发",
                     stopLoss: stopLoss, target: target, atr: 0.25)
}

private func packetQuote() -> Quote {
    Quote(security: Fixtures.security, price: 10.35, prevClose: 10.00, open: 10.10,
          high: 10.50, low: 10.05, volume: 120000, amount: 123456789,
          turnoverRate: 1.25, pe: 20, pb: 3, totalMarketCap: 5000,
          floatMarketCap: 4000, amplitude: 4.5, timestamp: Fixtures.date(days: 2))
}

private func packetLevel(price: Double, kind: LevelKind) -> PriceLevel {
    PriceLevel(price: price, kind: kind, score: 70, sources: [.swing],
               touches: 3, distancePct: 2.0)
}

private func packetFear(day: Int) -> FearSignal {
    FearSignal(kind: .panicCapitulation, score: 68, reason: "恐慌宣泄后企稳",
               price: 10.15, date: Fixtures.date(days: day))
}

private func packetEntry(minute: Int) -> BuyPointEntry {
    let trigger = IntradayTrigger(kind: .panicVReversal, direction: .buy, price: 10.30,
                                  time: Fixtures.date(minutes: minute), index: minute,
                                  strength: 73, reason: "V 型反转")
    return BuyPointEntry(security: Fixtures.security, price: 10.30, changePct: 3.0,
                         trigger: trigger, firstSeenAt: Fixtures.date(minutes: minute),
                         support: 10.0, resistance: 10.8, distanceToSupportPct: 3.0,
                         dailyGrade: nil, opportunityScore: nil)
}

private func packetEmotion() -> EmotionSnapshot {
    var breadth = MarketBreadth()
    breadth.total = 400
    breadth.advancing = 220
    breadth.limitUp = 30
    breadth.limitDown = 5
    breadth.sourceLabel = "竞价池 400 只"
    return EmotionSnapshot(score: 52, fear: 40, greed: 60, phase: .recovery,
                           headline: "恐慌缓解，承接开始出现", breadth: breadth,
                           updatedAt: Fixtures.date(days: 2))
}

private func packetInput() -> AnalysisPacket.Input {
    AnalysisPacket.Input(
        security: Fixtures.security,
        quote: packetQuote(),
        lastClose: 10.30,
        generatedAt: Fixtures.date(days: 2),
        summary: "趋势：震荡上行（强度 73）。",
        emotion: packetEmotion(),
        tradePoints: [packetPoint(day: 1, kind: .maPullback), packetPoint(day: 2, kind: .momentumSurge)],
        fearSignals: [packetFear(day: 2)],
        supports: [packetLevel(price: 9.80, kind: .support)],
        resistances: [packetLevel(price: 11.00, kind: .resistance)],
        intraday: [packetEntry(minute: 60)]
    )
}

private func firstOffset(of needle: String, in text: String) -> Int {
    guard let r = text.range(of: needle) else { return -1 }
    return text.distance(from: text.startIndex, to: r.lowerBound)
}

private func countOccurrences(_ needle: String, in text: String) -> Int {
    var count = 0
    var rest = text
    while let r = rest.range(of: needle) {
        count += 1
        rest = String(rest[r.upperBound...])
    }
    return count
}

// MARK: - 分析包格式

@Test func packetContainsAllSections() {
    let text = AnalysisPacket.build(packetInput())
    #expect(text.contains("[QuantLens 分析包]"))
    #expect(text.contains("贵州茅台"))
    #expect(text.contains("sh.600519"))
    #expect(text.contains("[行情]"))
    #expect(text.contains("[趋势与情绪]"))
    #expect(text.contains("[日线买卖点]"))
    #expect(text.contains("[恐惧 / 贪婪信号]"))
    #expect(text.contains("[支撑 / 压力]"))
    #expect(text.contains("[分时信号]"))
    #expect(text.contains("[待填] 持有成本：____"))
    #expect(text.contains("[待填] 仓位占比：____%"))
    #expect(text.contains("不构成投资建议"))
}

@Test func packetNumbersMatchInput() {
    let text = AnalysisPacket.build(packetInput())
    #expect(text.contains("10.35"))
    #expect(text.contains("10.20"))
    #expect(text.contains("9.80"))
    #expect(text.contains("11.00"))
    #expect(text.contains("B3"))
    #expect(text.contains("B4"))
    #expect(text.contains("均线回踩"))
    #expect(text.contains("恐慌企稳"))
    #expect(text.contains("回暖"))
    #expect(text.contains("V型反转"))
    // 哨兵数字绝不能出现：分析包不编造数字
    #expect(!text.contains("999.99"))
    #expect(!text.contains("888.88"))
}

@Test func packetEmptySectionsSayNone() {
    var input = packetInput()
    input.tradePoints = []
    input.fearSignals = []
    input.supports = []
    input.resistances = []
    input.intraday = []
    input.emotion = nil
    input.summary = ""
    let text = AnalysisPacket.build(input)
    #expect(text.contains("[日线买卖点]\n无。"))
    #expect(text.contains("[恐惧 / 贪婪信号]\n无。"))
    #expect(text.contains("支撑：无。"))
    #expect(text.contains("压力：无。"))
    #expect(text.contains("[分时信号]\n无。"))
    #expect(text.contains("暂无市场情绪快照。"))
    #expect(text.contains("[待填] 持有成本：____"))
}

@Test func packetTradePointsNewestFirst() {
    let text = AnalysisPacket.build(packetInput())
    let day2 = firstOffset(of: "B4", in: text)
    let day1 = firstOffset(of: "B3", in: text)
    #expect(day2 >= 0)
    #expect(day1 >= 0)
    #expect(day2 < day1)
}

@Test func packetLevelsNearestFirst() {
    var input = packetInput()
    // 价格与买卖点/行情数字互不重合，避免误匹配到别的区段
    input.supports = [packetLevel(price: 8.10, kind: .support),
                      packetLevel(price: 8.80, kind: .support),
                      packetLevel(price: 8.50, kind: .support)]
    input.resistances = [packetLevel(price: 12.50, kind: .resistance),
                         packetLevel(price: 12.00, kind: .resistance)]
    let text = AnalysisPacket.build(input)
    let near = firstOffset(of: "8.80", in: text)
    let far = firstOffset(of: "8.10", in: text)
    #expect(near >= 0)
    #expect(far >= 0)
    #expect(near < far)
    let nearR = firstOffset(of: "12.00", in: text)
    let farR = firstOffset(of: "12.50", in: text)
    #expect(nearR >= 0)
    #expect(farR >= 0)
    #expect(nearR < farR)
}

@Test func packetCapsTradePointsAtTen() {
    var input = packetInput()
    var points: [TradePointSignal] = []
    for day in 0..<12 {
        points.append(packetPoint(day: day, kind: .maPullback))
    }
    input.tradePoints = points
    let text = AnalysisPacket.build(input)
    #expect(countOccurrences("止损", in: text) == 10)
}

@Test func packetQuoteFallbackUsesLastClose() {
    var input = packetInput()
    input.quote = nil
    input.lastClose = 10.30
    let text = AnalysisPacket.build(input)
    #expect(text.contains("最新收盘 10.30"))
    #expect(!text.contains("暂无行情快照"))
}

@Test func packetNoQuoteNoCloseSaysNone() {
    var input = packetInput()
    input.quote = nil
    input.lastClose = nil
    let text = AnalysisPacket.build(input)
    #expect(text.contains("暂无行情快照。"))
}

// MARK: - 云端请求构造（不联网）

@Test func cloudChatRequestConstruction() {
    let points = [packetPoint(day: 2, kind: .maPullback)]
    let body = LLMPromptBuilder.requestBody(points: points, breadth: nil,
                                            model: "deepseek-chat", temperature: 0, maxTokens: 250)
    let url = URL(string: "https://api.deepseek.com/v1/chat/completions")!
    let req = CloudLLMClient.makeChatRequest(url: url, apiKey: "sk-test-key", body: body, timeout: 30)
    #expect(req != nil)
    guard let req = req else { return }
    #expect(req.url == url)
    #expect(req.httpMethod == "POST")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-key")
    #expect(req.timeoutInterval == 30)
    guard let data = req.httpBody else {
        #expect(Bool(false))
        return
    }
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        #expect(Bool(false))
        return
    }
    #expect(obj["model"] as? String == "deepseek-chat")
    #expect(obj["temperature"] as? Double == 0)
    #expect(obj["stream"] as? Bool == false)
    guard let messages = obj["messages"] as? [[String: Any]] else {
        #expect(Bool(false))
        return
    }
    #expect(messages.count == 2)
    #expect(messages[0]["role"] as? String == "system")
    #expect(messages[1]["role"] as? String == "user")
}

@Test func cloudModelsRequestConstruction() {
    let url = URL(string: "https://api.deepseek.com/v1/models")!
    let req = CloudLLMClient.makeModelsRequest(url: url, apiKey: "sk-test-key")
    #expect(req.url == url)
    #expect(req.httpMethod == "GET")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-key")
}

@Test func cloudParseContentReusesLocalParser() {
    let json = "{\"choices\":[{\"message\":{\"content\":\"均线回踩，强度 62。\"}}]}"
    let data = json.data(using: .utf8)!
    #expect(LocalLLMClient.parseContent(data) == "均线回踩，强度 62。")
    #expect(LocalLLMClient.parseContent(Data()) == nil)
}

// MARK: - 预设与配置

@Test func cloudPresetDefaults() {
    #expect(CloudLLMConfig.Preset.deepseek.baseURL == "https://api.deepseek.com/v1")
    #expect(CloudLLMConfig.Preset.deepseek.model == "deepseek-chat")
    #expect(CloudLLMConfig.Preset.dashscope.baseURL == "https://dashscope.aliyuncs.com/compatible-mode/v1")
    #expect(CloudLLMConfig.Preset.dashscope.model == "qwen-plus")
    #expect(CloudLLMConfig.Preset.custom.baseURL == "")
    #expect(CloudLLMConfig.Preset.custom.model == "")
    let def = CloudLLMConfig()
    #expect(def.preset == .deepseek)
    #expect(def.baseURL == CloudLLMConfig.Preset.deepseek.baseURL)
    #expect(def.model == CloudLLMConfig.Preset.deepseek.model)
    #expect(def.enabled == false)
}

@Test func cloudConfigCodableRoundtrip() {
    var cfg = CloudLLMConfig()
    cfg.enabled = true
    cfg.preset = .dashscope
    cfg.baseURL = "https://example.com/v1"
    cfg.model = "custom-model"
    let data = try! JSONEncoder().encode(cfg)
    let back = try! JSONDecoder().decode(CloudLLMConfig.self, from: data)
    #expect(back == cfg)
    // Key 绝不能出现在编码后的配置里
    let text = String(data: data, encoding: .utf8) ?? ""
    #expect(!text.contains("apiKey"))
    #expect(!text.contains("key"))
}

@Test func cloudConfigUsableAndURLs() {
    var cfg = CloudLLMConfig()
    #expect(cfg.isUsable == false)
    cfg.enabled = true
    #expect(cfg.isUsable == true)
    cfg.model = ""
    #expect(cfg.isUsable == false)
    cfg.model = "deepseek-chat"
    cfg.baseURL = ""
    #expect(cfg.isUsable == false)
    cfg.baseURL = "https://api.deepseek.com/v1"
    #expect(cfg.chatURL?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
    #expect(cfg.modelsURL?.absoluteString == "https://api.deepseek.com/v1/models")
    cfg.baseURL = "https://api.deepseek.com/v1/"
    #expect(cfg.chatURL?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
}

// MARK: - Keychain 接口（内存兜底，不触真实钥匙串）

@Test func memoryKeychainRoundtrip() {
    let service = "QuantLens.Test"
    let account = "roundtrip"
    MemoryKeychain.delete(service: service, account: account)
    #expect(MemoryKeychain.load(service: service, account: account) == nil)
    #expect(MemoryKeychain.save("sk-first", service: service, account: account) == true)
    #expect(MemoryKeychain.load(service: service, account: account) == "sk-first")
    #expect(MemoryKeychain.save("sk-second", service: service, account: account) == true)
    #expect(MemoryKeychain.load(service: service, account: account) == "sk-second")
    MemoryKeychain.delete(service: service, account: account)
    #expect(MemoryKeychain.load(service: service, account: account) == nil)
}

#if !canImport(Security)
@Test func keychainStoreRoutesToMemoryFallback() {
    let service = "QuantLens.Test"
    let account = "fallback"
    KeychainStore.delete(service: service, account: account)
    #expect(KeychainStore.load(service: service, account: account) == nil)
    #expect(KeychainStore.save("sk-x", service: service, account: account) == true)
    #expect(KeychainStore.load(service: service, account: account) == "sk-x")
    KeychainStore.delete(service: service, account: account)
    #expect(KeychainStore.load(service: service, account: account) == nil)
}

@Test func cloudKeyStorageRoundtrip() {
    CloudLLMConfig.deleteKey()
    #expect(CloudLLMConfig.hasKey() == false)
    #expect(CloudLLMConfig.saveKey("sk-cloud-test") == true)
    #expect(CloudLLMConfig.hasKey() == true)
    #expect(CloudLLMConfig.loadKey() == "sk-cloud-test")
    CloudLLMConfig.deleteKey()
    #expect(CloudLLMConfig.hasKey() == false)
}
#endif

// MARK: - 云端解释回落（不联网）

@Test func cloudExplainFallsBackWhenDisabled() async {
    var cfg = CloudLLMConfig()
    cfg.enabled = false
    let points = [packetPoint(day: 2, kind: .maPullback)]
    let result = await CloudLLMClient.shared.explain(points: points, breadth: nil,
                                                     config: cfg, apiKey: "sk-test")
    #expect(result.fromLLM == false)
    #expect(result.text == SignalExplainer.explainBatch(points))
}

@Test func cloudExplainFallsBackWhenEmptyPoints() async {
    var cfg = CloudLLMConfig()
    cfg.enabled = true
    let result = await CloudLLMClient.shared.explain(points: [], breadth: nil,
                                                     config: cfg, apiKey: "sk-test")
    #expect(result.fromLLM == false)
    #expect(result.text.isEmpty)
}

@Test func cloudExplainFallsBackWithoutKey() async {
    var cfg = CloudLLMConfig()
    cfg.enabled = true
    let points = [packetPoint(day: 2, kind: .maPullback)]
    let result = await CloudLLMClient.shared.explain(points: points, breadth: nil,
                                                     config: cfg, apiKey: "")
    #expect(result.fromLLM == false)
    #expect(result.text == SignalExplainer.explainBatch(points))
}
