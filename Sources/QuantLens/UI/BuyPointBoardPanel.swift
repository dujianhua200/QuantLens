import AppKit

// MARK: - 今日机会榜

/// 日线 + 分时 + 竞价三源合成的机会榜：
/// - 分时：`AppState.buyPointEntries`（盘中轮询的分时触发，新触发置顶高亮）
/// - 日线：最近一次日线扫描的恐惧/贪婪信号（`ScanResult.fearSignals`）
/// - 竞价：`AppState.auctionState.picks`（集合竞价选股结果）
/// 顶部是情绪温度计（情绪分 + 周期相位 + 一句话解读），筛选芯片切换来源。
/// 点行预览该标的（不加入自选），与扫描结果的点击行为一致。
final class BuyPointBoardPanel: PanelBase {

    /// 榜单筛选
    private enum BoardFilter: String, CaseIterable {
        case all = "全部"
        case intraday = "分时"
        case daily = "日线"
        case auction = "竞价"
    }

    private let body = FlippedStackView()
    private var rows: [OpportunityBoardRow] = []
    private let statusLabel = L.label("", size: 8, color: Theme.textFaint)
    private let hintLabel = L.wrapped("", size: 8.5)
    private let reasonLabel = L.wrapped("", size: 8.5, color: Theme.textDim)
    private let autoButton = NSButton()
    private let refreshButton = NSButton()

    // 情绪温度计
    private let emotionTitleLabel = L.label("情绪采集中…", size: 8.5, weight: .semibold, color: Theme.textDim)
    private let emotionSourceLabel = L.label("", size: 7.5, color: Theme.textFaint)
    private let emotionBar = EmotionBarView()
    private let emotionHeadlineLabel = L.wrapped("", size: 8, color: Theme.textFaint)
    private let emotionHintLabel = L.label("", size: 7.5, color: Theme.textFaint)

    private var filterButtons: [BoardFilter: NSButton] = [:]
    private var filter: BoardFilter = .all

    private let maxRows = 8

    init() {
        super.init(title: "今日机会榜", icon: "bolt.fill")

        // ---- 情绪温度计 ----
        let emotionHead = L.hstack([emotionTitleLabel, L.spacer(), emotionSourceLabel], spacing: 6)
        addBody(emotionHead)
        emotionBar.translatesAutoresizingMaskIntoConstraints = false
        emotionBar.heightAnchor.constraint(equalToConstant: 10).isActive = true
        addBody(emotionBar)
        let scaleRow = L.hstack([
            L.label("恐惧", size: 7.5, color: Theme.textFaint),
            L.spacer(),
            L.label("中性", size: 7.5, color: Theme.textFaint),
            L.spacer(),
            L.label("贪婪", size: 7.5, color: Theme.textFaint)
        ], spacing: 4)
        addBody(scaleRow)
        addBody(emotionHeadlineLabel)
        addBody(emotionHintLabel)

        // ---- 筛选芯片 + 轮询控制 ----
        var chipViews: [NSView] = []
        for f in BoardFilter.allCases {
            let b = NSButton()
            b.title = f.rawValue
            b.isBordered = false
            b.bezelStyle = .inline
            b.font = Fonts.ui(8, weight: .medium)
            b.target = self
            b.action = #selector(tapFilter(_:))
            b.setContentHuggingPriority(.required, for: .horizontal)
            filterButtons[f] = b
            chipViews.append(b)
        }
        autoButton.title = "自动：开"
        autoButton.isBordered = false
        autoButton.bezelStyle = .inline
        autoButton.font = Fonts.ui(8, weight: .medium)
        autoButton.contentTintColor = Theme.accent
        autoButton.target = self
        autoButton.action = #selector(toggleAuto)
        autoButton.setContentHuggingPriority(.required, for: .horizontal)

        refreshButton.title = "刷新"
        refreshButton.isBordered = false
        refreshButton.bezelStyle = .inline
        refreshButton.font = Fonts.ui(8, weight: .medium)
        refreshButton.contentTintColor = Theme.accent
        refreshButton.target = self
        refreshButton.action = #selector(refreshNow)
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)

        chipViews.append(L.spacer())
        chipViews.append(autoButton)
        chipViews.append(refreshButton)
        let chipRow = L.hstack(chipViews, spacing: 6)
        addBody(chipRow)

        addBody(statusLabel)

        // 表头
        let header = L.hstack([
            colLabel("", 8, .left),
            colLabel("名称", 42, .left),
            colLabel("现价", 44, .right),
            colLabel("涨跌", 42, .right),
            colLabel("信号", 52, .left),
            colLabel("来源", 32, .right),
            colLabel("备注", 62, .right)
        ], spacing: 3)
        addBody(header)

        // 列表（行复用，避免每轮重建视图）
        body.orientation = .vertical
        body.spacing = 1
        body.alignment = .leading
        body.distribution = .fill
        body.translatesAutoresizingMaskIntoConstraints = false

        for _ in 0..<maxRows {
            let row = OpportunityBoardRow()
            row.isHidden = true
            row.onSelect = { sec in AppState.shared.preview(sec) }
            rows.append(row)
            body.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 16).isActive = true
        }
        addBody(body)

        hintLabel.isHidden = true
        addBody(hintLabel)

        reasonLabel.isHidden = true
        addBody(reasonLabel)

        let disclaimer = L.label("仅供娱乐与技术研究，不构成投资建议", size: 7.5, color: Theme.textFaint)
        addBody(disclaimer)

        NotificationCenter.default.addObserver(self, selector: #selector(onBoardChange),
                                               name: AppState.didChangeBuyPoints, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onBoardChange),
                                               name: AppState.didChangeScan, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onBoardChange),
                                               name: AppState.didChangeAuction, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onBoardChange),
                                               name: AppState.didChangeEmotion, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func onBoardChange() { reload() }

    @objc private func toggleAuto() {
        let app = AppState.shared
        app.setBuyPointAutoEnabled(!app.buyPointAutoEnabled)
        reload()
    }

    @objc private func refreshNow() {
        Task { await AppState.shared.refreshBuyPointBoard() }
    }

    @objc private func tapFilter(_ sender: NSButton) {
        for (f, b) in filterButtons where b === sender {
            filter = f
            reload()
            return
        }
    }

    private func colLabel(_ text: String, _ width: CGFloat, _ align: NSTextAlignment) -> NSTextField {
        let l = L.label(text, size: 7.5, color: Theme.textFaint)
        l.alignment = align
        if width > 0 { l.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return l
    }

    private func phaseColor(_ phase: EmotionPhase) -> NSColor {
        switch phase {
        case .ice: return Theme.accent
        case .recovery: return Theme.down
        case .chaos: return Theme.flat
        case .euphoria: return Theme.up
        case .ebb: return Theme.risk
        }
    }

    private func reload() {
        let app = AppState.shared

        // ---- 情绪温度计 ----
        if let snap = app.emotionSnapshot {
            let pc = phaseColor(snap.phase)
            emotionTitleLabel.stringValue = "情绪 \(Fmt.price(snap.score, decimals: 0)) 分 · \(snap.phase.rawValue)"
            emotionTitleLabel.textColor = pc
            emotionSourceLabel.stringValue = snap.breadth.sourceLabel
            emotionBar.score = snap.score
            emotionBar.phaseColor = pc
            emotionBar.needsDisplay = true
            emotionHeadlineLabel.stringValue = snap.headline
            emotionHeadlineLabel.isHidden = false
            emotionHintLabel.stringValue = "\(snap.phase.hint)；\(snap.phase.positionHint)"
            emotionHintLabel.isHidden = false
        } else {
            emotionTitleLabel.stringValue = "情绪采集中…"
            emotionTitleLabel.textColor = Theme.textDim
            emotionSourceLabel.stringValue = ""
            emotionBar.score = 50
            emotionBar.phaseColor = Theme.flat
            emotionBar.needsDisplay = true
            emotionHeadlineLabel.isHidden = true
            emotionHintLabel.isHidden = true
        }

        // ---- 筛选芯片 ----
        for (f, b) in filterButtons {
            let selected = (f == filter)
            b.contentTintColor = selected ? Theme.accent : Theme.textFaint
            b.font = Fonts.ui(8, weight: selected ? .semibold : .medium)
        }

        autoButton.title = app.buyPointAutoEnabled ? "自动：开" : "自动：关"
        autoButton.contentTintColor = app.buyPointAutoEnabled ? Theme.accent : Theme.textFaint

        if app.isBuyPointScanning {
            statusLabel.stringValue = "扫描中…"
            statusLabel.textColor = Theme.accent
        } else {
            statusLabel.stringValue = app.buyPointStatus
            statusLabel.textColor = Theme.textFaint
        }

        // ---- 三源合成行 ----
        let allRows = buildRows(app: app)
        let entries = Array(allRows.prefix(maxRows))
        hintLabel.isHidden = !entries.isEmpty || app.isBuyPointScanning
        if entries.isEmpty {
            switch filter {
            case .all:
                hintLabel.stringValue = "暂无机会信号：分时触发、日线情绪信号与竞价候选会在这里上榜。"
            case .intraday:
                hintLabel.stringValue = "暂无分时触发：盘中出现回踩均价、V 型反转等信号时，这里会实时上榜（仅 A 股）。"
            case .daily:
                hintLabel.stringValue = "暂无日线情绪信号：点「开盘扫描」后，恐慌企稳、诱空等日线信号会在这里上榜。"
            case .auction:
                hintLabel.stringValue = "暂无竞价候选：09:15 竞价开始后自动采样，或点底部竞价榜「立即扫描」。"
            }
        }
        if let first = entries.first {
            reasonLabel.stringValue = "依据：\(first.reasonText)"
            reasonLabel.isHidden = false
        } else {
            reasonLabel.isHidden = true
        }
        for (i, row) in rows.enumerated() {
            if i < entries.count {
                row.configure(entries[i])
                row.isHidden = false
            } else {
                row.isHidden = true
            }
        }
    }

    /// 按当前筛选构建统一行数据。
    private func buildRows(app: AppState) -> [OpportunityRowData] {
        var out: [OpportunityRowData] = []

        if filter == .all || filter == .intraday {
            for e in app.buyPointEntries {
                let dir = e.trigger.direction.shortLabel
                let sigColor = e.trigger.direction == .buy ? Theme.up : Theme.down
                var note = "撑 —"
                if let s = e.support {
                    if let d = e.distanceToSupportPct {
                        note = "撑 \(Fmt.price(s)) \(Fmt.pct(-d, decimals: 1))"
                    } else {
                        note = "撑 \(Fmt.price(s))"
                    }
                }
                out.append(OpportunityRowData(
                    security: e.security,
                    name: e.security.name.isEmpty ? e.security.displayCode : e.security.name,
                    price: e.price,
                    changePct: e.changePct,
                    signalText: "\(dir) \(e.trigger.kind.label)",
                    signalColor: sigColor,
                    isNew: e.isNew,
                    timeText: Fmt.intradayFormatter.string(from: e.firstSeenAt),
                    noteText: note,
                    reasonText: e.trigger.reason,
                    sortScore: e.trigger.strength
                ))
            }
        }

        if filter == .all || filter == .daily {
            var daily: [OpportunityRowData] = []
            for r in app.scanResults {
                guard let top = r.fearSignals.first else { continue }
                let dir = top.direction.shortLabel
                let sigColor = top.direction == .buy ? Theme.up : Theme.down
                daily.append(OpportunityRowData(
                    security: r.security,
                    name: r.security.name.isEmpty ? r.security.displayCode : r.security.name,
                    price: r.price,
                    changePct: r.changePct,
                    signalText: "\(dir) \(top.kind.shortLabel)",
                    signalColor: sigColor,
                    isNew: false,
                    timeText: "日线",
                    noteText: "\(top.sentiment.rawValue) \(Fmt.price(top.score, decimals: 0))分",
                    reasonText: top.reason,
                    sortScore: top.score
                ))
            }
            daily.sort { $0.sortScore > $1.sortScore }
            out.append(contentsOf: daily)
        }

        if filter == .all || filter == .auction {
            for p in app.auctionState.picks {
                let sigColor: NSColor
                switch p.auctionClass {
                case .panicRepair: sigColor = Theme.accent
                case .cashOutRisk: sigColor = Theme.risk
                case .sweetSpot: sigColor = Theme.up
                case .normal: sigColor = Theme.textDim
                }
                let gapText = p.gapPct >= 0
                    ? "高开 \(Fmt.pct(p.gapPct, decimals: 1))"
                    : "低开 \(Fmt.pct(p.gapPct, decimals: 1))"
                out.append(OpportunityRowData(
                    security: p.security,
                    name: p.name.isEmpty ? p.security.displayCode : p.name,
                    price: p.matchPrice,
                    changePct: p.gapPct,
                    signalText: "竞 \(p.auctionClass.rawValue)",
                    signalColor: sigColor,
                    isNew: false,
                    timeText: "竞价",
                    noteText: gapText,
                    reasonText: p.reasons.first ?? "集合竞价选股",
                    sortScore: p.score
                ))
            }
        }

        // 全部筛选时：新触发优先，其次按强度
        if filter == .all {
            out.sort {
                if $0.isNew != $1.isNew { return $0.isNew }
                return $0.sortScore > $1.sortScore
            }
        }
        return out
    }
}

// MARK: - 情绪温度条

final class EmotionBarView: NSView {
    var score: Double = 50
    var phaseColor: NSColor = Theme.flat

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let barH: CGFloat = 6
        let barRect = NSRect(x: 0, y: (bounds.height - barH) / 2,
                             width: bounds.width, height: barH)
        ctx.fillRoundedRect(barRect, radius: 3, color: Theme.panel3)
        let frac = CGFloat(max(0, min(100, score)) / 100)
        if frac > 0.01 {
            let fillRect = NSRect(x: 0, y: barRect.minY, width: barRect.width * frac, height: barH)
            ctx.fillRoundedRect(fillRect, radius: 3, color: phaseColor)
        }
        // 50 分中性刻度
        let midX = barRect.width * 0.5
        ctx.strokeLine(from: CGPoint(x: midX, y: barRect.minY - 1),
                       to: CGPoint(x: midX, y: barRect.maxY + 1),
                       color: Theme.textFaint, width: 1)
    }
}

// MARK: - 机会榜统一行数据

struct OpportunityRowData {
    var security: Security
    var name: String
    var price: Double
    var changePct: Double
    var signalText: String
    var signalColor: NSColor
    var isNew: Bool
    var timeText: String
    var noteText: String
    var reasonText: String
    var sortScore: Double
}

// MARK: - 机会榜行

final class OpportunityBoardRow: NSView {
    var onSelect: ((Security) -> Void)?

    private let dotLabel = L.label("", size: 8, color: Theme.up)
    private let nameLabel = L.label("", size: 8.5, weight: .medium)
    private let priceLabel = L.label("", size: 8, color: Theme.text, mono: true)
    private let changeLabel = L.label("", size: 8, mono: true)
    private let signalLabel = L.label("", size: 8, weight: .medium)
    private let timeLabel = L.label("", size: 8, color: Theme.textDim, mono: true)
    private let noteLabel = L.label("", size: 8, color: Theme.textDim, mono: true)
    private var entry: OpportunityRowData?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 3

        dotLabel.widthAnchor.constraint(equalToConstant: 8).isActive = true
        nameLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        priceLabel.alignment = .right
        priceLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        changeLabel.alignment = .right
        changeLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        signalLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        timeLabel.alignment = .right
        timeLabel.widthAnchor.constraint(equalToConstant: 32).isActive = true
        noteLabel.alignment = .right
        noteLabel.widthAnchor.constraint(equalToConstant: 62).isActive = true

        let row = L.hstack([dotLabel, nameLabel, priceLabel, changeLabel,
                            signalLabel, timeLabel, noteLabel], spacing: 3)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(click)
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    @objc private func tapped() {
        if let e = entry { onSelect?(e.security) }
    }

    override func mouseEntered(with event: NSEvent) {
        if entry?.isNew != true {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.045).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = (entry?.isNew == true)
            ? Theme.buy.withAlphaComponent(0.09).cgColor
            : NSColor.clear.cgColor
    }

    func configure(_ e: OpportunityRowData) {
        entry = e

        // 新触发高亮：红点 + 底色
        dotLabel.stringValue = e.isNew ? "●" : ""
        layer?.backgroundColor = e.isNew
            ? Theme.buy.withAlphaComponent(0.09).cgColor
            : NSColor.clear.cgColor

        nameLabel.stringValue = e.name
        nameLabel.textColor = e.isNew ? Theme.text : Theme.textDim
        priceLabel.stringValue = Fmt.price(e.price)
        changeLabel.stringValue = Fmt.pct(e.changePct, decimals: 1)
        changeLabel.textColor = Theme.color(change: e.changePct)

        signalLabel.stringValue = e.signalText
        signalLabel.textColor = e.signalColor

        timeLabel.stringValue = e.timeText
        noteLabel.stringValue = e.noteText
    }
}
