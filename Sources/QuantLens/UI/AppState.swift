import AppKit
import Foundation

// MARK: - 自选股持久化

struct WatchItem: Codable, Hashable {
    var security: Security
    var addedAt: Date = Date()

    var id: String { security.id }
}

// MARK: - 应用状态

/// 全局状态容器。AppKit 下用 NotificationCenter 广播变更，
/// 各视图自行刷新，避免绑定框架的复杂度。
final class AppState {

    static let shared = AppState()

    static let didChangeData = Notification.Name("QuantLens.didChangeData")
    static let didChangeSelection = Notification.Name("QuantLens.didChangeSelection")
    static let didChangeQuotes = Notification.Name("QuantLens.didChangeQuotes")
    static let didChangeStatus = Notification.Name("QuantLens.didChangeStatus")
    static let didChangeWatchlist = Notification.Name("QuantLens.didChangeWatchlist")
    static let didChangeScan = Notification.Name("QuantLens.didChangeScan")
    static let didChangeBuyPoints = Notification.Name("QuantLens.didChangeBuyPoints")
    static let didChangeAI = Notification.Name("QuantLens.didChangeAI")
    static let didRequestAISettings = Notification.Name("QuantLens.didRequestAISettings")
    static let didChangeIntraday = Notification.Name("QuantLens.didChangeIntraday")
    static let didChangeTrades = Notification.Name("QuantLens.didChangeTrades")
    static let didChangeLargeOrderScan = Notification.Name("QuantLens.didChangeLargeOrderScan")
    static let didChangeAuction = Notification.Name("QuantLens.didChangeAuction")
    static let didChangeLocalVerdict = Notification.Name("QuantLens.didChangeLocalVerdict")
    static let didChangeStrategy = Notification.Name("QuantLens.didChangeStrategy")
    static let didChangeFundamental = Notification.Name("QuantLens.didChangeFundamental")

    // 自选
    private(set) var watchlist: [WatchItem] = []
    /// 自选列表中被高亮的行（可能为 nil，表示当前在看的是预览标的）
    private(set) var selectedID: String?

    // 行情
    var period: KPeriod = .day
    private(set) var data: StockData?
    private(set) var analysis: Analysis?
    private(set) var backtest: [BacktestResult] = []
    private(set) var quotes: [String: Quote] = [:]

    // 盘中数据
    private(set) var intraday: IntradayData?
    private(set) var orderBook: OrderBook?
    private(set) var trades: [Trade] = []
    /// 大单预警（最近 30 条）
    private(set) var largeOrderAlerts: [LargeOrderAlert] = []
    /// 是否显示分时图（false 则显示 K 线）
    var showIntraday = true
    /// 盘中刷新间隔（秒）
    var intradayRefreshInterval: Double = 3

    // 大单扫描（全自选）
    private(set) var largeOrderScans: [LargeOrderScanResult] = []
    private(set) var isScanningLargeOrders = false
    private(set) var largeOrderProgress: (done: Int, total: Int) = (0, 0)

    // 扫描
    private(set) var scanResults: [ScanResult] = []
    private(set) var isScanning = false
    private(set) var scanProgress: (done: Int, total: Int) = (0, 0)
    private(set) var lastScanAt: Date?

    // MARK: - 实时短线买点榜（分时触发，盘中轮询）

    private(set) var buyPointEntries: [BuyPointEntry] = []
    private(set) var isBuyPointScanning = false
    private(set) var lastBuyPointScanAt: Date?
    private(set) var buyPointStatus: String = ""
    /// 盘中自动轮询开关（默认开；非交易时段由时段门控自动停，不空转）
    var buyPointAutoEnabled = true
    /// 两轮扫描的最小间隔（秒）。分时点每分钟才新增一个，60 秒足够实时。
    var buyPointInterval: TimeInterval = 60
    /// 自动开盘扫描
    var autoScanEnabled = false
    var autoScanHour = 9
    var autoScanMinute = 35

    // AI
    var aiConfig = AIConfig.load()
    private(set) var aiVerdicts: [String: AIVerdict] = [:]
    private(set) var aiStatus: String = ""
    private(set) var isAIReviewing = false
    private(set) var aiLastError: String?
    private(set) var aiLastReviewAt: Date?

    // 状态
    private(set) var isLoading = false
    private(set) var lastUpdate: Date?
    private(set) var errorMessage: String?

    // 显示选项
    var showMarkers = true
    var showLevels = true
    var showMA = true
    var showBoll = false
    var subIndicator: SubIndicator = .volume
    var autoRefresh = true
    var refreshInterval: Double = 15

    /// 加载序号：快速切换标的时，丢弃过期响应，避免旧数据覆盖新数据
    private var loadGeneration = 0
    /// 盘中请求是否在途
    private var isIntradayFetching = false
    /// 逐笔成交是否在途（独立于分时盘口）
    private var isTradesFetching = false
    /// 盘中请求对应的标的 id
    private var intradayTargetID: String?

    private var refreshTimer: Timer?
    private var intradayTimer: Timer?
    private var autoScanTimer: Timer?
    private var buyPointTimer: Timer?
    /// 触发 id -> 首次出现时间（跨轮次保留，用于“新触发”高亮）
    private var buyPointFirstSeen: [String: Date] = [:]
    private var scanTask: Task<Void, Never>?
    private let scanLock = NSLock()

    // MARK: - 集合竞价选股

    /// 竞价选股运行状态（UI 直接读）
    private(set) var auctionState = AuctionRunState()
    /// 竞价扫描是否开启（用户开关，默认开启）
    var auctionAutoEnabled = true

    // MARK: - 本地智能分析（零 Key）

    /// 当前标的的本地分析结论
    private(set) var localVerdict: LocalAnalyst.Verdict?
    /// 该结论对应的标的 id（防止切标的后残留上一只的标记）
    private(set) var localVerdictTargetID: String?
    /// 分析是否在途
    private(set) var isAnalyzing = false
    /// 上次分析时间
    private(set) var lastAnalysisAt: Date?
    /// 当前标的的战法识别结果
    private(set) var strategyResult: StrategySignals.Result?
    /// 回测统计（手动触发）
    private(set) var backtestStats: [StrategyBacktest.Stat] = []
    private(set) var isBacktesting = false
    /// 自选股基本面实证排名
    private(set) var fundamentalScores: [FundamentalSelector.Score] = []
    private var auctionTimer: Timer?
    private var auctionTask: Task<Void, Never>?
    /// 非交易时段是否已做过一次引导采样（避免每次 tick 重复拉数据）
    private var didBootstrapAuction = false

    /// 当前竞价阶段
    var auctionPhase: AuctionPhase { AuctionScanner.phase() }

    private init() {
        loadWatchlist()
        if watchlist.isEmpty {
            watchlist = Self.defaultWatchlist
            saveWatchlist()
        }
        selectedID = watchlist.first?.id
        currentSecurity = watchlist.first?.security
    }

    static let defaultWatchlist: [WatchItem] = [
        WatchItem(security: Security(symbol: "600519", name: "贵州茅台", market: .sh)),
        WatchItem(security: Security(symbol: "000001", name: "平安银行", market: .sz)),
        WatchItem(security: Security(symbol: "300750", name: "宁德时代", market: .sz)),
        WatchItem(security: Security(symbol: "601318", name: "中国平安", market: .sh)),
        WatchItem(security: Security(symbol: "002594", name: "比亚迪", market: .sz)),
        WatchItem(security: Security(symbol: "688981", name: "中芯国际", market: .sh)),
        WatchItem(security: Security(symbol: "00700", name: "腾讯控股", market: .hk)),
        WatchItem(security: Security(symbol: "AAPL", name: "苹果", market: .us)),
        WatchItem(security: Security(symbol: "sh000001", name: "上证指数", market: .index)),
        WatchItem(security: Security(symbol: "sz399006", name: "创业板指", market: .index))
    ]

    /// 当前正在查看的标的。
    ///
    /// 与自选列表解耦：用户可以从搜索结果「预览」任意标的看图表，
    /// 而不必先加入自选。这是主流行情软件的标准交互
    ///（同花顺：点搜索结果只切图，点「+」才加自选）。
    private(set) var currentSecurity: Security?

    /// 最近浏览（含未自选的），最多 15 条
    private(set) var recentViews: [Security] = []

    /// 当前查看的标的。优先用 currentSecurity，兜底用自选第一只。
    var selected: Security? {
        if let c = currentSecurity { return c }
        if let id = selectedID, let item = watchlist.first(where: { $0.id == id }) {
            return item.security
        }
        return watchlist.first?.security
    }

    /// 当前标的是否已在自选里
    var isCurrentInWatchlist: Bool {
        guard let c = selected else { return false }
        return watchlist.contains { $0.id == c.id }
    }

    var selectedQuote: Quote? {
        guard let id = selectedID else { return nil }
        return quotes[id]
    }

    var selectedVerdict: AIVerdict? {
        guard let sec = selected else { return nil }
        return aiVerdicts[sec.displayCode]
    }

    // MARK: - 自选管理

    /// 加入自选。只写列表，不打断当前看图。
    /// 返回是否真的新增了（已存在返回 false）。
    @discardableResult
    func add(_ security: Security) -> Bool {
        if watchlist.contains(where: { $0.id == security.id }) {
            // 已存在：只把高亮同步过去
            selectedID = security.id
            notify(Self.didChangeWatchlist)
            return false
        }
        watchlist.append(WatchItem(security: security))
        // 如果当前看的正是这只，就把高亮打上；否则不动当前视图
        if currentSecurity?.id == security.id {
            selectedID = security.id
        }
        saveWatchlist()
        notify(Self.didChangeWatchlist)
        Task {
            await self.refreshQuotesOnly()
        }
        return true
    }

    /// 只刷新快照，不重新加载K线（避免打断正在看的图）
    private func refreshQuotesOnly() async {
        let securities = watchlist.map(\.security)
        let map = await MarketService.shared.refreshQuotes(securities: securities)
        guard !map.isEmpty else { return }
        for (k, v) in map { quotes[k] = v }
        var changed = false
        for (i, item) in watchlist.enumerated() {
            if let q = map[item.security.id], !q.security.name.isEmpty {
                let clean = SecuritySearchService.unescapeUnicode(q.security.name)
                if item.security.name != clean {
                    watchlist[i].security = Security(symbol: item.security.symbol,
                                                    name: clean,
                                                    market: item.security.market)
                    changed = true
                }
            }
        }
        if changed { saveWatchlist() }
        lastUpdate = Date()
        notifyQuotes()
        notify(Self.didChangeWatchlist)
    }

    /// 从当前查看的标的加入自选
    @discardableResult
    func addCurrentToWatchlist() -> Bool {
        guard let c = currentSecurity else { return false }
        return add(c)
    }

    func remove(_ id: String) {
        let wasCurrent = (currentSecurity?.id == id)
        watchlist.removeAll { $0.id == id }
        saveWatchlist()

        if wasCurrent {
            // 删掉正在看的，回退到自选第一只
            currentSecurity = watchlist.first?.security
            selectedID = watchlist.first?.id
            notifySelection()
            Task { await loadSelected() }
        } else if selectedID == id {
            selectedID = nil
        }
        notify(Self.didChangeWatchlist)
    }

    private func recordRecent(_ sec: Security) {
        recentViews.removeAll { $0.id == sec.id }
        recentViews.insert(sec, at: 0)
        if recentViews.count > 15 { recentViews.removeLast(recentViews.count - 15) }
    }

    private func saveWatchlist() {
        if let d = try? JSONEncoder().encode(watchlist) {
            UserDefaults.standard.set(d, forKey: "QuantLens.watchlist.v2")
        }
    }

    private func loadWatchlist() {
        guard let d = UserDefaults.standard.data(forKey: "QuantLens.watchlist.v2"),
              let items = try? JSONDecoder().decode([WatchItem].self, from: d) else { return }
        // 修复历史数据：早期版本把 smartbox 的 \uXXXX 转义直接存进了名称
        var repaired = false
        watchlist = items.map { item in
            var it = item
            if it.security.name.contains("\\u") {
                it.security = Security(
                    symbol: it.security.symbol,
                    name: SecuritySearchService.unescapeUnicode(it.security.name),
                    market: it.security.market
                )
                repaired = true
            }
            return it
        }
        // 清理历史错误：早期版本把中文名误判成美股（us.五粮液），或把A股代码挂在 us 市场
        watchlist = watchlist.filter { item in
            if item.security.market == .us {
                let sym = item.security.symbol
                // 美股代码必须全是 ASCII 字母
                let valid = !sym.isEmpty && sym.allSatisfy { ch in
                    guard let a = ch.asciiValue else { return false }
                    return (65...90).contains(a) || (97...122).contains(a) || a == 46 || a == 45
                }
                if !valid { repaired = true; return false }
            }
            return true
        }
        if repaired { saveWatchlist() }
    }

    // MARK: - 通知

    private func notify(_ name: Notification.Name) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: name, object: nil)
        }
    }

    func notifyData() { notify(Self.didChangeData) }
    func notifySelection() { notify(Self.didChangeSelection) }
    func notifyQuotes() {
        notify(Self.didChangeQuotes)
        // 估值随行情更新，重算基本面排名（轻量，仅内存计算）
        rankWatchlistByFundamentals()
    }
    private func notifyStatus() { notify(Self.didChangeStatus) }

    // MARK: - 刷新

    func startAutoRefresh() {
        refreshTimer?.invalidate()
        guard autoRefresh else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshAll(silent: true) }
        }
        if let t = refreshTimer { RunLoop.main.add(t, forMode: .common) }
    }

    /// 启动全部定时器
    func startTimers() {
        startAutoRefresh()
        startIntradayRefresh()
        startAuctionMonitor()
        startBuyPointMonitor()
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refreshAll(silent: Bool = false) async {
        if !silent {
            isLoading = true
            notifyStatus()
        }
        defer {
            if !silent {
                isLoading = false
                notifyStatus()
            }
        }

        let securities = watchlist.map(\.security)
        let map = await MarketService.shared.refreshQuotes(securities: securities)

        if !map.isEmpty {
            for (k, v) in map { quotes[k] = v }
            var changed = false
            for (i, item) in watchlist.enumerated() {
                if let q = map[item.security.id], !q.security.name.isEmpty {
                    let clean = SecuritySearchService.unescapeUnicode(q.security.name)
                    if item.security.name != clean {
                        watchlist[i].security = Security(symbol: item.security.symbol,
                                                        name: clean,
                                                        market: item.security.market)
                        changed = true
                    }
                }
            }
            if changed {
                saveWatchlist()
                notify(Self.didChangeWatchlist)
            }
            lastUpdate = Date()
            notifyQuotes()
        } else if !silent {
            errorMessage = "行情获取失败，请检查网络"
            notifyStatus()
        }

        await loadSelected(silentUpdate: silent)
    }

    func loadSelected(silentUpdate: Bool = false) async {
        guard let sec = selected else { return }
        let p = period

        // 每次加载递增序号；返回时若序号已变，说明用户已经切走，丢弃本次结果
        loadGeneration += 1
        let generation = loadGeneration

        if !silentUpdate {
            isLoading = true
            notifyStatus()
        }

        let result = await MarketService.shared.load(security: sec, period: p)

        // 过期响应：直接丢弃，不污染当前视图
        guard generation == loadGeneration else { return }

        guard !result.candles.isEmpty else {
            // 只在确实是当前标的时才报错
            if selected?.id == sec.id {
                errorMessage = "\(sec.displayCode) 未获取到K线数据"
                isLoading = false
                notifyStatus()
            }
            return
        }

        errorMessage = nil
        data = result
        if let q = result.quote {
            quotes[sec.id] = q
        }

        let a = SignalEngine.analyze(data: result, period: p)
        analysis = a
        // K线就绪后立即评估战法
        strategyResult = StrategySignals.evaluate(candles: result.candles)
        notify(Self.didChangeStrategy)
        backtest = BacktestEngine.runAll(ctx: a.context)

        isLoading = false
        notifyData()
        notifyStatus()
    }

    func setPeriod(_ p: KPeriod) {
        guard p != period else { return }
        period = p
        notifySelection()
        Task { await loadSelected() }
    }

    /// 点击自选行：切图 + 高亮该行
    func select(_ id: String) {
        guard let item = watchlist.first(where: { $0.id == id }) else { return }
        // 即使已经是当前标的，也要保证高亮一致
        let changed = (currentSecurity?.id != item.security.id) || (selectedID != id)
        selectedID = id
        currentSecurity = item.security
        recordRecent(item.security)
        guard changed else { return }
        intraday = nil
        orderBook = nil
        trades = []
        clearLocalVerdict()
        strategyResult = nil
        notify(Self.didChangeStrategy)
        notify(Self.didChangeIntraday)
        notify(Self.didChangeTrades)
        notify(Self.didChangeWatchlist)
        notifySelection()
        Task { await loadSelected() }
    }

    /// 预览任意标的（不加入自选）。
    /// 用于：点搜索结果、点扫描结果、搜索框回车。
    func preview(_ security: Security) {
        if currentSecurity?.id == security.id { return }
        currentSecurity = security
        recordRecent(security)
        // 切标的：清空旧盘中数据，避免显示上一只的盘口
        intraday = nil
        orderBook = nil
        trades = []
        largeOrderAlerts = []
        clearLocalVerdict()
        strategyResult = nil
        notify(Self.didChangeStrategy)
        notify(Self.didChangeIntraday)
        notify(Self.didChangeTrades)
        // 如果这个标的恰好在自选里，同步高亮；否则清空高亮
        selectedID = watchlist.first { $0.id == security.id }?.id
        notify(Self.didChangeWatchlist)
        notifySelection()
        Task { await loadSelected() }
    }

    /// 预览裸代码（搜索框回车 / 代码直达）
    func previewRawCode(_ raw: String) {
        guard let sec = SecurityFactory.fromRawInput(raw) else { return }
        preview(sec)
    }

    // MARK: - 自选排序与批量操作

    enum WatchSort: String, CaseIterable {
        case manual = "手动"
        case changeDesc = "涨幅"
        case changeAsc = "跌幅"
        case name = "名称"

        var label: String { rawValue }
    }

    private(set) var watchSort: WatchSort = .manual

    /// 按当前排序规则返回自选（不修改存储顺序）
    var sortedWatchlist: [WatchItem] {
        switch watchSort {
        case .manual:
            return watchlist
        case .changeDesc:
            return watchlist.sorted {
                (quotes[$0.id]?.changePct ?? -999) > (quotes[$1.id]?.changePct ?? -999)
            }
        case .changeAsc:
            return watchlist.sorted {
                (quotes[$0.id]?.changePct ?? 999) < (quotes[$1.id]?.changePct ?? 999)
            }
        case .name:
            return watchlist.sorted { $0.security.name < $1.security.name }
        }
    }

    func setWatchSort(_ s: WatchSort) {
        watchSort = s
        notify(Self.didChangeWatchlist)
    }

    /// 置顶某只自选
    func moveToTop(_ id: String) {
        guard let idx = watchlist.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        let item = watchlist.remove(at: idx)
        watchlist.insert(item, at: 0)
        watchSort = .manual
        saveWatchlist()
        notify(Self.didChangeWatchlist)
    }

    /// 单独扫描一只，并把结果插到最前
    func scanSingle(_ security: Security) {
        Task { [weak self] in
            guard let self else { return }
            self.isScanning = true
            self.scanProgress = (0, 1)
            self.notify(Self.didChangeScan)
            if let r = await ScanEngine.evaluate(security, period: self.period) {
                self.scanResults = [r] + self.scanResults.filter { $0.security.id != r.security.id }
                self.lastScanAt = Date()
            }
            self.isScanning = false
            self.notify(Self.didChangeScan)
        }
    }

    /// 在自选列表里上下移动（↑/↓ 键）
    func stepWatchlist(_ delta: Int) {
        guard !watchlist.isEmpty else { return }
        let currentID = selected?.id
        var idx = watchlist.firstIndex { $0.id == currentID } ?? -1
        idx += delta
        if idx < 0 { idx = watchlist.count - 1 }
        if idx >= watchlist.count { idx = 0 }
        select(watchlist[idx].id)
    }

    /// 周期前进/后退（←/→ 键，或 [ ]）
    func stepPeriod(_ delta: Int) {
        let all = KPeriod.allCases
        guard let cur = all.firstIndex(of: period) else { return }
        var next = cur + delta
        if next < 0 { next = all.count - 1 }
        if next >= all.count { next = 0 }
        setPeriod(all[next])
    }

    /// 切换分时 / K线
    func toggleIntraday(_ show: Bool) {
        showIntraday = show
        if show {
            startIntradayRefresh()
            Task { await refreshIntraday() }
        } else {
            stopIntradayRefresh()
        }
        notify(Self.didChangeIntraday)
    }

    // MARK: - 盘中数据

    /// 启动盘中轮询（分时 + 盘口 + 逐笔）
    func startIntradayRefresh() {
        intradayTimer?.invalidate()
        guard showIntraday else { return }

        // 用 Timer 但显式加入 common mode（滚动/拖拽时也要跑）
        let t = Timer(timeInterval: intradayRefreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshIntraday(silent: true)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        intradayTimer = t
    }

    func stopIntradayRefresh() {
        intradayTimer?.invalidate()
        intradayTimer = nil
    }

    // MARK: - 集合竞价选股

    /// 启动竞价选股监控。开盘竞价窗口（09:15–09:25）内每 3 秒采样一次，
    /// 09:25 出结果；其余时间每 60 秒检查是否进入窗口。
    func startAuctionMonitor() {
        stopAuctionMonitor()
        guard auctionAutoEnabled else { return }

        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.auctionTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        auctionTimer = t

        // 立即跑一次，让 UI 尽快拿到状态
        Task { @MainActor in await self.auctionTick() }
    }

    func stopAuctionMonitor() {
        auctionTimer?.invalidate()
        auctionTimer = nil
        auctionTask?.cancel()
        auctionTask = nil
    }

    /// 每个 tick 依据当前阶段决定行为
    private func auctionTick() async {
        let phase = AuctionScanner.phase()
        auctionState.phase = phase

        switch phase {
        case .earlyNoisy, .locked:
            // 竞价窗口内密集采样
            if auctionTask == nil {
                auctionState.isRunning = true
                auctionState.message = phase.hint
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.runAuctionLoop()
                }
                auctionTask = task
            }

        case .settled:
            // 09:25 之后（含盘中 9:30-15:00）：
            // 若从未采样过（例如 App 启动时已过竞价窗口），主动拉一次实时数据，
            // 让用户打开就能看到榜单，而不是空白。
            auctionState.isRunning = false
            auctionTask?.cancel()
            auctionTask = nil
            let sampled = await AuctionScanner.shared.sampleCodeCount
            if sampled == 0 && !didBootstrapAuction {
                auctionState.message = "正在拉取实时行情…"
                let n = await AuctionScanner.shared.sampleOnce(forcePool: true)
                // 采样成功才标记，失败则下一个 tick 重试
                didBootstrapAuction = n > 0
            }
            await finalizeAuction()
            auctionState.message = auctionState.picks.isEmpty
                ? "当前无符合高开条件的标的（可点「立即扫描」重试）"
                : "当前高开 \(auctionState.picks.count) 只（实时行情快照）"

        default:
            // 非交易窗口
            auctionState.isRunning = false
            auctionTask?.cancel()
            auctionTask = nil
            auctionState.message = phase.hint
        }

        notify(Self.didChangeAuction)
    }

    /// 竞价窗口内的采样循环
    private func runAuctionLoop() async {
        while !Task.isCancelled {
            let phase = AuctionScanner.phase()
            guard phase == .earlyNoisy || phase == .locked else { break }

            let n = await AuctionScanner.shared.sampleOnce()
            let cand = await AuctionScanner.shared.candidateCount
            let sampled = await AuctionScanner.shared.sampleCodeCount

            await MainActor.run {
                self.auctionState.candidates = cand
                self.auctionState.scanned = sampled
                self.auctionState.lastSampleAt = Date()
                self.auctionState.phase = phase
                self.auctionState.message = phase.hint
                // 锁定期的中间结果实时刷新榜单
                if phase == .locked {
                    Task {
                        let picks = await AuctionScanner.shared.evaluate()
                        await MainActor.run {
                            self.auctionState.picks = picks
                            self.notify(Self.didChangeAuction)
                        }
                    }
                }
                self.notify(Self.didChangeAuction)
            }

            if n == 0 && cand == 0 {
                await MainActor.run {
                    self.auctionState.message = "候选池为空，等待行情源恢复"
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    /// 09:25 出最终结果
    private func finalizeAuction() async {
        let picks = await AuctionScanner.shared.evaluate()
        auctionState.picks = picks
        auctionState.lastSampleAt = Date()
        auctionState.phase = AuctionScanner.phase()
        notify(Self.didChangeAuction)
    }

    /// 手动触发一次竞价扫描（用户点按钮用，非交易时段也能看候选池）
    func auctionScanNow() async {
        auctionState.message = "正在拉取候选池…"
        notify(Self.didChangeAuction)
        let n = await AuctionScanner.shared.sampleOnce(forcePool: true)
        let cand = await AuctionScanner.shared.candidateCount
        let picks = await AuctionScanner.shared.evaluate()
        auctionState.candidates = cand
        auctionState.scanned = await AuctionScanner.shared.sampleCodeCount
        auctionState.lastSampleAt = Date()
        auctionState.phase = AuctionScanner.phase()
        auctionState.picks = picks
        if n == 0 {
            auctionState.message = "行情源无响应，稍后重试"
        } else if picks.isEmpty {
            auctionState.message = "已采样 \(n) 条，当前无高开达标标的"
        } else {
            auctionState.message = "采样 \(n) 条，选出 \(picks.count) 只"
        }
        notify(Self.didChangeAuction)
    }

    /// 拉取当前标的的盘中数据
    func refreshIntraday(silent: Bool = false) async {
        let sel = selected
        guard let sec = sel else { return }
        guard sec.market == .sh || sec.market == .sz || sec.market == .bj else {
            // 港美股无分时/逐笔接口
            intraday = nil
            orderBook = nil
            trades = []
            notify(Self.didChangeIntraday)
            notify(Self.didChangeTrades)
            return
        }

        // 同一时刻只允许一个盘中请求在途，避免自相作废
        if isIntradayFetching {
            return
        }
        isIntradayFetching = true

        let targetID = sec.id
        intradayTargetID = targetID

        // 分时 + 盘口 快速并取（都不探测页号，毫秒级）
        async let intradayTask: IntradayData? = {
            try? await IntradayService.shared.intraday(security: sec)
        }()
        async let bookTask: OrderBook? = {
            try? await IntradayService.shared.orderBook(security: sec)
        }()
        let (i, b) = await (intradayTask, bookTask)

        // 标的已切换则丢弃
        guard intradayTargetID == targetID, selected?.id == targetID else {
            isIntradayFetching = false
            return
        }

        intraday = i
        orderBook = b
        isIntradayFetching = false
        notify(Self.didChangeIntraday)

        // 自动研判：本地引擎零成本，让每只股票切过去都有买卖标记，
        // 不必每次手动点「AI 分析」。仅当当前标的尚无有效结论时才跑。
        if let d = i, !d.points.isEmpty,
           localVerdictTargetID != targetID || localVerdict == nil {
            // 日线背景是研判的核心依据，K 线未就绪时先补上
            if data?.security.id != targetID {
                await loadSelected(silentUpdate: true)
            }
            let verdict = LocalAnalyst.analyze(
                intraday: d,
                book: b,
                floatCap: quotes[targetID]?.floatMarketCap ?? 0,
                daily: buildDailyBias()
            )
            guard selected?.id == targetID else { return }
            localVerdict = verdict
            localVerdictTargetID = targetID
            lastAnalysisAt = Date()
            notify(Self.didChangeLocalVerdict)
        }

        // 逐笔独立异步派发：不阻塞分时首屏，也不阻塞下一次 refreshIntraday 拿分时
        if !isTradesFetching {
            isTradesFetching = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.fetchTradesSeparate(for: sec, targetID: targetID)
                self.isTradesFetching = false
            }
        }
    }

    /// 独立拉取逐笔成交，成功后追加大单预警并通知。慢速路径，不与分时争抢。
    private func fetchTradesSeparate(for sec: Security, targetID: String) async {
        guard intradayTargetID == targetID, selected?.id == targetID else { return }
        let fresh = (try? await IntradayService.shared.trades(security: sec, pages: 2, latest: true)) ?? []
        guard intradayTargetID == targetID, selected?.id == targetID else { return }

        let oldSeqs = Set(trades.map(\.sequence))
        let newTrades = fresh.filter { !oldSeqs.contains($0.sequence) }
        trades = fresh

        for tr in newTrades where tr.volume >= 500 || tr.amount >= 3_000_000 {
            let level: LargeOrderAlert.AlertLevel = (tr.volume >= 2000 || tr.amount >= 10_000_000) ? .huge : .large
            largeOrderAlerts.insert(LargeOrderAlert(security: sec, trade: tr, level: level), at: 0)
        }
        if largeOrderAlerts.count > 30 {
            largeOrderAlerts.removeLast(largeOrderAlerts.count - 30)
        }
        notify(Self.didChangeTrades)
    }

    // MARK: - 一键智能分析（本地引擎，零 Key / 零 Token）

    /// 点一下「AI 分析」，立刻用本地引擎判断走势并给出买卖点位。
    /// 不联网、不消耗 token，离线也能用。
    func analyzeNow() async {
        guard let sec = selected else { return }
        isAnalyzing = true
        notify(Self.didChangeLocalVerdict)

        if intraday == nil || intradayTargetID != sec.id {
            await refreshIntraday()
        }

        var data = intraday
        if data == nil {
            data = try? await IntradayService.shared.intraday(security: sec)
            if let d = data, sec.id == selected?.id {
                intraday = d
            }
        }

        guard let intradayData = data, !intradayData.points.isEmpty else {
            localVerdict = nil
            localVerdictTargetID = nil
            isAnalyzing = false
            notify(Self.didChangeLocalVerdict)
            return
        }

        let book = orderBook
        let cap = quotes[sec.id]?.floatMarketCap ?? 0
        var verdict = LocalAnalyst.analyze(
            intraday: intradayData,
            book: book,
            floatCap: cap,
            daily: buildDailyBias()
        )

        // 用实证信号覆盖/约束研判结论
        if let kd = self.data, kd.security.id == sec.id, kd.candles.count >= 65 {
            verdict = applyEmpirical(verdict, candles: kd.candles)
        }

        guard selected?.id == sec.id else {
            isAnalyzing = false
            return
        }

        localVerdict = verdict
        localVerdictTargetID = sec.id
        lastAnalysisAt = Date()
        isAnalyzing = false
        notify(Self.didChangeLocalVerdict)
    }

    /// 用全市场实测结论修正研判。
    ///
    /// 实测数据（4838只×3年，318万样本，日度聚合t检验）显示：
    /// 追涨类形态（放量上攻/强势上涨/放量收高）显著跑输，t低至-11；
    /// 抄底类形态正期望全部不显著（t<2）。
    /// 因此这里以「风险规避」为主，而不是给出买入推荐。
    private func applyEmpirical(_ v: LocalAnalyst.Verdict,
                                candles: [Candle]) -> LocalAnalyst.Verdict {
        let assess = EmpiricalSignals.assess(candles: candles)
        guard !assess.findings.isEmpty else {
            var out = v
            out.reasons.append("实证：当前无统计显著的短期形态")
            return out
        }

        var out = v
        // 记录命中的实证信号
        for f in assess.findings {
            let tag = f.level == .strongAvoid ? "⛔" : (f.level == .avoid ? "⚠️" : "○")
            out.reasons.append(String(format: "%@ %@：实测5日超额 %+.2f%%（t=%.1f）",
                                      tag, f.name, f.edge, f.tStat))
        }

        // 强回避信号：直接否定买入
        if assess.worstLevel == .strongAvoid {
            out.isBuyNow = false
            out.action = "回避"
            out.confidence = max(20, out.confidence - 35)
            out.summary = assess.headline + "。实证数据不支持此刻买入。"
            out.risks.append("追涨型形态历史负期望极显著，不要在拉升当天进场")
            out.buyMarks = []
        } else if assess.worstLevel == .avoid {
            out.isBuyNow = false
            if out.action == "强烈买入" || out.action == "买入" {
                out.action = "观察"
            }
            out.confidence = max(25, out.confidence - 20)
            out.summary = assess.headline + "。" + out.summary
            out.risks.append("该形态历史为负期望，建议等待更好的位置")
        }

        // 用实证区间覆盖买卖位（更可信）
        if let lv = EmpiricalSignals.levels(candles: candles) {
            // 仅在原判据偏乐观时收敛
            if out.isBuyNow {
                out.buyZone = (max(lv.buyLow, 0), lv.buyHigh)
                out.sellZone = (lv.sellLow, lv.sellHigh)
                out.stopLoss = lv.stop
            }
            out.reasons.append("实证区间：" + lv.basis)
        }

        return out
    }

    /// 从当前 K 线数据构造日线背景，供本地研判做趋势约束。
    /// 数据不足时返回 nil，研判会退化为纯分时判断并标注风险。
    func buildDailyBias() -> LocalAnalyst.DailyBias? {
        guard let d = data, d.candles.count >= 20 else { return nil }
        // 关键：K 线必须属于当前标的。切换股票后 loadSelected 是异步的，
        // 这里若拿到上一只的 K 线，会把别人的趋势套到当前股票上。
        if let cur = currentSecurity, d.security.id != cur.id { return nil }
        let candles = d.candles
        let closes = candles.map(\.close)
        let n = closes.count
        guard let last = closes.last, last > 0 else { return nil }

        func sma(_ arr: [Double], _ period: Int) -> Double? {
            guard arr.count >= period else { return nil }
            let slice = arr.suffix(period)
            return slice.reduce(0, +) / Double(period)
        }

        let ma20 = sma(closes, 20)
        let ma60 = sma(closes, 60)

        // MA20 斜率：当前 MA20 相对 5 日前 MA20 的变化 %
        var slope = 0.0
        if n >= 25 {
            let prevSlice = Array(closes[(n - 25)..<(n - 5)])
            if let prevMA = sma(prevSlice, 20), let curMA = ma20, prevMA > 0 {
                slope = (curMA - prevMA) / prevMA * 100
            }
        }

        // 近 20 日涨跌
        var chg20 = 0.0
        if n >= 21 {
            let base = closes[n - 21]
            if base > 0 { chg20 = (last - base) / base * 100 }
        }

        // 趋势方向：用现有分析结果，没有就用均线关系推断
        var trend: TrendDirection = .sideways
        if let t = analysis?.context.trend {
            trend = t.direction
        } else if let m20 = ma20, let m60 = ma60 {
            if last > m20 && m20 > m60 && slope > 0.3 { trend = .strongUp }
            else if last > m20 { trend = .up }
            else if last < m20 && m20 < m60 { trend = .strongDown }
            else if last < m20 { trend = .down }
        }

        // ATR：近 20 日真实波幅均值，占价格百分比
        var atrPct = 2.0
        if candles.count >= 20 {
            let recent = candles.suffix(20)
            var trSum = 0.0
            var prevCloseV: Double?
            for c in recent {
                let h = c.high, l = c.low
                if let pc = prevCloseV {
                    trSum += max(h - l, abs(h - pc), abs(l - pc))
                } else {
                    trSum += h - l
                }
                prevCloseV = c.close
            }
            let atr = trSum / Double(recent.count)
            if last > 0 { atrPct = atr / last * 100 }
        }

        // 近 20 日高低点
        var low20 = 0.0, high20 = 0.0
        if candles.count >= 20 {
            let recent = candles.suffix(20)
            low20 = recent.map(\.low).min() ?? 0
            high20 = recent.map(\.high).max() ?? 0
        }

        // 量能趋势：近 5 日均量 / 近 20 日均量
        var volTrend = 1.0
        if candles.count >= 20 {
            let vols = candles.map(\.volume)
            let v5 = vols.suffix(5).reduce(0, +) / 5
            let v20 = vols.suffix(20).reduce(0, +) / 20
            if v20 > 0 { volTrend = v5 / v20 }
        }

        return LocalAnalyst.DailyBias(
            trend: trend,
            vsMA20: ma20.map { (last - $0) / $0 * 100 } ?? 0,
            vsMA60: ma60.map { (last - $0) / $0 * 100 } ?? 0,
            ma20Slope: slope,
            belowMA20: ma20.map { last < $0 } ?? false,
            belowMA60: ma60.map { last < $0 } ?? false,
            change20D: chg20,
            atrPct: atrPct,
            ma20Value: ma20 ?? 0,
            ma60Value: ma60 ?? 0,
            low20D: low20,
            high20D: high20,
            volTrendRatio: volTrend
        )
    }

    // MARK: - 基本面实证选股

    /// 对自选股按实证因子打分排序。
    /// 数据来自实时行情的 PE/PB/总市值（腾讯行情字段），无需额外 API。
    /// 因子权重来自全市场 159,190 个月度样本的 t 值归一化。
    func rankWatchlistByFundamentals() {
        let inputs = watchlist.compactMap { item -> (code:String, name:String, mcap:Double,
                                                      pb:Double, pe:Double, ps:Double?)? in
            guard let q = quotes[item.id] else { return nil }
            guard q.totalMarketCap > 0, q.pe > 0, q.pb > 0 else { return nil }
            let code = item.security.symbol
            return (code, item.security.name, q.totalMarketCap, q.pb, q.pe, nil)
        }
        fundamentalScores = FundamentalSelector.rank(inputs)
        notify(Self.didChangeFundamental)
    }

    // MARK: - 战法识别与回测

    /// 对当前标的执行战法识别
    func evaluateStrategies() {
        guard let d = data, d.candles.count >= 30 else {
            strategyResult = nil
            notify(Self.didChangeStrategy)
            return
        }
        strategyResult = StrategySignals.evaluate(candles: d.candles)
        notify(Self.didChangeStrategy)
    }

    /// 回测当前自选股池，用真实历史数据验证战法
    func runStrategyBacktest() async {
        guard !isBacktesting else { return }
        isBacktesting = true
        notify(Self.didChangeStrategy)

        // 拉取自选股的日线
        var all: [[Candle]] = []
        for item in watchlist {
            let m = item.security.market
            guard m == .sh || m == .sz else { continue }
            if let d = try? await MarketService.shared.load(security: item.security, period: .day) {
                if d.candles.count >= 160 { all.append(d.candles) }
            }
        }

        let stats = StrategyBacktest.runAggregate(all: all)
        backtestStats = stats
        isBacktesting = false
        notify(Self.didChangeStrategy)
    }

    /// 清除分析结果（切标的时调用）
    func clearLocalVerdict() {
        guard localVerdict != nil || localVerdictTargetID != nil else { return }
        localVerdict = nil
        localVerdictTargetID = nil
        notify(Self.didChangeLocalVerdict)
    }

    /// 当前结论是否属于当前标的（用于图上标注的合法性校验）
    var localVerdictMatchesSelection: Bool {
        guard let t = localVerdictTargetID, let cur = currentSecurity?.id else { return false }
        return t == cur
    }

    /// 选中某只竞价结果并切换到它的分时图。
    /// 竞价票大多不在自选列表里，必须走 preview（可切任意标的），
    /// 用 select 会因为在 watchlist 里找不到而静默失效。
    func selectAuctionPick(_ pick: AuctionPick) {
        if watchlist.contains(where: { $0.id == pick.security.id }) {
            select(pick.security.id)
        } else {
            preview(pick.security)
        }
    }

    /// 全自选大单扫描：并发拉逐笔，统计大单净额
    func scanLargeOrders() {
        guard !isScanningLargeOrders else { return }
        var targets: [Security] = []
        for item in watchlist {
            let m = item.security.market
            if m == .sh || m == .sz || m == .bj {
                targets.append(item.security)
            }
        }
        guard !targets.isEmpty else { return }

        isScanningLargeOrders = true
        largeOrderProgress = (0, targets.count)
        notify(Self.didChangeLargeOrderScan)

        Task { [weak self] in
            guard let self else { return }
            var out: [LargeOrderScanResult] = []
            var done = 0

            // 分 3 个一批，避免打爆接口
            for chunk in targets.chunked(into: 3) {
                await withTaskGroup(of: LargeOrderScanResult?.self) { group in
                    for sec in chunk {
                        group.addTask {
                            guard let trades = try? await IntradayService.shared.trades(
                                security: sec, pages: 2, latest: true
                            ), !trades.isEmpty else { return nil }
                            let stats = LargeOrderStats.summarize(trades, threshold: .medium)
                            guard stats.totalAmount > 0 else { return nil }
                            return LargeOrderScanResult(
                                security: sec,
                                buyCount: stats.buyCount,
                                buyAmount: stats.buyAmount,
                                sellCount: stats.sellCount,
                                sellAmount: stats.sellAmount,
                                netAmount: stats.netAmount,
                                buyRatio: stats.buyRatio
                            )
                        }
                    }
                    for await r in group {
                        if let r { out.append(r) }
                    }
                }
                done += chunk.count
                self.largeOrderProgress = (done, targets.count)
                self.notify(Self.didChangeLargeOrderScan)
                if done < targets.count {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }

            self.largeOrderScans = out.sorted { $0.netAmount > $1.netAmount }
            self.isScanningLargeOrders = false
            self.notify(Self.didChangeLargeOrderScan)
        }
    }

    // MARK: - 扫描

    func startScan(includeAI: Bool = true) {
        guard !isScanning else { return }
        let targets = watchlist.map(\.security)
        guard !targets.isEmpty else { return }

        isScanning = true
        aiLastError = nil
        scanProgress = (0, targets.count)
        notify(Self.didChangeScan)

        scanTask = Task { [weak self] in
            guard let self else { return }
            let results = await ScanEngine.scan(
                securities: targets,
                options: .init(period: self.period, maxConcurrent: 3)
            ) { done, total in
                Task { @MainActor in
                    self.scanProgress = (done, total)
                    NotificationCenter.default.post(name: Self.didChangeScan, object: nil)
                }
            }

            self.scanResults = results
            self.lastScanAt = Date()
            self.isScanning = false
            self.notify(Self.didChangeScan)

            // AI 复核
            if includeAI && self.aiConfig.isUsable && !results.isEmpty {
                await self.runAIReview(candidates: results)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        notify(Self.didChangeScan)
    }

    // MARK: - AI

    func runAIReview(candidates: [ScanResult]? = nil) async {
        guard aiConfig.isUsable else {
            aiLastError = "AI 未配置"
            notify(Self.didChangeAI)
            return
        }
        let pool = candidates ?? scanResults
        guard !pool.isEmpty else {
            aiLastError = "没有可送审的标的，请先扫描"
            notify(Self.didChangeAI)
            return
        }

        isAIReviewing = true
        aiStatus = "AI 复核中…"
        aiLastError = nil
        notify(Self.didChangeAI)

        // 只送机会分最高的若干只，控制 token 成本和响应时间
        let shortlist = Array(pool.prefix(aiConfig.maxCandidatesPerScan))
        let result = await AIClient.shared.reviewScan(results: shortlist, analysis: analysis, config: aiConfig)

        switch result {
        case .success(let verdicts):
            aiVerdicts = verdicts
            aiStatus = "AI 已复核 \(verdicts.count) 只"
            aiLastReviewAt = Date()
        case .failure(let err):
            aiLastError = err.errorDescription ?? "AI 复核失败"
            aiStatus = "AI 复核失败"
        }

        isAIReviewing = false
        notify(Self.didChangeAI)
        notify(Self.didChangeScan)
    }

    func testAIConnection() async -> String {
        let r = await AIClient.shared.testConnection(config: aiConfig)
        switch r {
        case .success(let msg):
            aiStatus = "连接正常：\(msg)"
            notify(Self.didChangeAI)
            return "✓ 连接正常（模型回复：\(msg)）"
        case .failure(let err):
            aiLastError = err.errorDescription
            notify(Self.didChangeAI)
            return "✗ \(err.errorDescription ?? "失败")"
        }
    }

    func saveAIConfig(_ config: AIConfig) {
        aiConfig = config
        config.save()
        notify(Self.didChangeAI)
    }

    // MARK: - 自动扫描（开盘定时）

    func startAutoScan() {
        autoScanTimer?.invalidate()
        guard autoScanEnabled else { return }

        // 每 30 秒检查一次是否到达预定时间
        autoScanTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let cal = Calendar.current
            let now = Date()
            let comps = cal.dateComponents([.hour, .minute], from: now)
            guard comps.hour == self.autoScanHour, comps.minute == self.autoScanMinute else { return }

            // 当天只跑一次
            let key = "QuantLens.lastAutoScan"
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let today = df.string(from: now)
            if UserDefaults.standard.string(forKey: key) == today { return }
            UserDefaults.standard.set(today, forKey: key)

            self.startScan(includeAI: true)
        }
        if let t = autoScanTimer { RunLoop.main.add(t, forMode: .common) }
    }

    // MARK: - 实时短线买点榜

    /// 启动买点榜轮询：每 30 秒检查一次，交易时段内、距上次扫描超过
    /// `buyPointInterval` 时才跑一轮；非交易时段只更新状态文字，不发请求。
    func startBuyPointMonitor() {
        buyPointTimer?.invalidate()
        buyPointTimer = nil
        guard buyPointAutoEnabled else { return }

        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.buyPointTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        buyPointTimer = t

        // 立即跑一次，让打开 App 就能看到榜单状态
        Task { @MainActor in await self.buyPointTick() }
    }

    func stopBuyPointMonitor() {
        buyPointTimer?.invalidate()
        buyPointTimer = nil
    }

    /// 面板开关：切换自动轮询。
    func setBuyPointAutoEnabled(_ enabled: Bool) {
        buyPointAutoEnabled = enabled
        if enabled {
            startBuyPointMonitor()
        } else {
            stopBuyPointMonitor()
            buyPointStatus = "自动刷新已关闭，可点「刷新」手动扫描"
            notify(Self.didChangeBuyPoints)
        }
    }

    private func buyPointTick() async {
        guard buyPointAutoEnabled else { return }
        guard TradingHours.isAStockTrading() else {
            // 非交易时段不空转：只在状态变化时通知一次，避免每 30 秒刷面板
            let msg = "非交易时段，买点榜暂停刷新"
            if buyPointStatus != msg {
                buyPointStatus = msg
                notify(Self.didChangeBuyPoints)
            }
            return
        }
        if let last = lastBuyPointScanAt, Date().timeIntervalSince(last) < buyPointInterval { return }
        await refreshBuyPointBoard()
    }

    /// 扫描全部 A 股自选的分时触发，刷新买点榜。
    ///
    /// 请求约束与 `ScanEngine.scan` 一致：每批 3 只并发、批次间隔 180ms，
    /// 避免打爆免费接口。每只只拉分时（1 个请求），不拉 K 线与资金流；
    /// 日线支撑/分级取自最近一次日线扫描结果，没有也不阻塞。
    /// 港美股无分时接口，不进入本榜（日线扫描不受影响）。
    func refreshBuyPointBoard() async {
        guard !isBuyPointScanning else { return }
        let targets = watchlist.map(\.security).filter {
            $0.market == .sh || $0.market == .sz || $0.market == .bj
        }
        guard !targets.isEmpty else {
            buyPointStatus = "自选里没有 A 股标的"
            notify(Self.didChangeBuyPoints)
            return
        }

        isBuyPointScanning = true
        buyPointStatus = "正在扫描分时买点…"
        notify(Self.didChangeBuyPoints)

        // 日线背景按标的事先取好，任务内只捕获标量，避免跨任务共享可变状态
        let dailyByID = Dictionary(uniqueKeysWithValues: scanResults.map { ($0.security.id, $0) })
        struct Job {
            var security: Security
            var support: Double?
            var resistance: Double?
            var grade: ScanGrade?
            var opportunity: Double?
        }
        let jobs = targets.map { sec -> Job in
            let d = dailyByID[sec.id]
            return Job(security: sec, support: d?.support, resistance: d?.resistance,
                       grade: d?.grade, opportunity: d?.opportunityScore)
        }

        var entries: [BuyPointEntry] = []
        let chunks = jobs.chunked(into: 3)
        for (chunkIndex, chunk) in chunks.enumerated() {
            await withTaskGroup(of: BuyPointEntry?.self) { group in
                for job in chunk {
                    group.addTask {
                        guard let d = try? await IntradayService.shared.intraday(security: job.security),
                              d.points.count >= 10 else { return nil }
                        let triggers = IntradaySignals.evaluate(intraday: d)
                        guard let top = triggers.first else { return nil }
                        let levels = IntradayLevels.compute(
                            intraday: d,
                            dailySupport: job.support,
                            dailyResistance: job.resistance
                        )
                        return BuyPointEntry(
                            security: job.security,
                            price: d.lastPrice,
                            changePct: d.lastChangePct,
                            trigger: top,
                            firstSeenAt: Date(),
                            support: levels.support,
                            resistance: levels.resistance,
                            distanceToSupportPct: levels.distanceToSupportPct,
                            dailyGrade: job.grade,
                            opportunityScore: job.opportunity
                        )
                    }
                }
                for await e in group {
                    if let e { entries.append(e) }
                }
            }
            // 批次之间留间隔，避免触发免费接口限流
            if chunkIndex < chunks.count - 1 {
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
        }

        // 合并首次出现时间：已在榜上的触发沿用旧时间，新触发记当前时间；
        // 已消失的触发从记录中清理，下次再出现时重新算“新触发”。
        let now = Date()
        var seenIDs = Set<String>()
        var merged: [BuyPointEntry] = []
        for var e in entries {
            if let prev = buyPointFirstSeen[e.id] {
                e.firstSeenAt = prev
            } else {
                e.firstSeenAt = now
                buyPointFirstSeen[e.id] = now
            }
            seenIDs.insert(e.id)
            merged.append(e)
        }
        buyPointFirstSeen = buyPointFirstSeen.filter { seenIDs.contains($0.key) }

        // 排序：新触发优先，其次按触发强度
        buyPointEntries = merged.sorted {
            if $0.isNew != $1.isNew { return $0.isNew }
            return $0.trigger.strength > $1.trigger.strength
        }
        lastBuyPointScanAt = now
        isBuyPointScanning = false
        buyPointStatus = buyPointEntries.isEmpty
            ? "本轮无分时触发"
            : "共 \(buyPointEntries.count) 只触发 · \(Fmt.intradayFormatter.string(from: now))"
        notify(Self.didChangeBuyPoints)
    }

    // MARK: - 搜索

    func search(_ keyword: String) async -> [SearchHit] {
        await SecuritySearchService.shared.search(keyword)
    }
}