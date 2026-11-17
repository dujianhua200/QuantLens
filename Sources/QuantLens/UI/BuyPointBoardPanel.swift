import AppKit

// MARK: - 实时短线买点榜

/// 盘中实时刷新的分时触发榜单：自选股一旦出现回踩均价、放量突破等
/// 短线触发就上榜，新触发置顶并高亮，显示触发时间、触发依据与最近支撑。
/// 数据来自 `AppState.buyPointEntries`（分时轮询，见 AppState 买点榜一节）。
/// 点行预览该标的（不加入自选），与扫描结果的点击行为一致。
final class BuyPointBoardPanel: PanelBase {

    private let body = FlippedStackView()
    private var rows: [BuyPointBoardRow] = []
    private let statusLabel = L.label("", size: 8, color: Theme.textFaint)
    private let hintLabel = L.wrapped("暂无分时触发：盘中出现回踩均价、放量突破等信号时，这里会实时上榜（仅 A 股）。", size: 8.5)
    private let reasonLabel = L.wrapped("", size: 8.5, color: Theme.textDim)
    private let autoButton = NSButton()
    private let refreshButton = NSButton()

    private let maxRows = 8

    init() {
        super.init(title: "短线买点榜", icon: "bolt.fill")

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

        let headRow = L.hstack([statusLabel, L.spacer(), autoButton, refreshButton], spacing: 6)
        addBody(headRow)

        // 表头
        let header = L.hstack([
            colLabel("", 8, .left),
            colLabel("名称", 42, .left),
            colLabel("现价", 44, .right),
            colLabel("涨跌", 42, .right),
            colLabel("触发", 52, .left),
            colLabel("时间", 32, .right),
            colLabel("支撑", 62, .right)
        ], spacing: 3)
        addBody(header)

        // 列表（行复用，避免每轮重建视图）
        body.orientation = .vertical
        body.spacing = 1
        body.alignment = .leading
        body.distribution = .fill
        body.translatesAutoresizingMaskIntoConstraints = false

        for _ in 0..<maxRows {
            let row = BuyPointBoardRow()
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

        let disclaimer = L.label("仅供娱乐，不构成投资建议", size: 7.5, color: Theme.textFaint)
        addBody(disclaimer)

        NotificationCenter.default.addObserver(self, selector: #selector(onBuyPoints),
                                               name: AppState.didChangeBuyPoints, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func onBuyPoints() { reload() }

    @objc private func toggleAuto() {
        let app = AppState.shared
        app.setBuyPointAutoEnabled(!app.buyPointAutoEnabled)
        reload()
    }

    @objc private func refreshNow() {
        Task { await AppState.shared.refreshBuyPointBoard() }
    }

    private func colLabel(_ text: String, _ width: CGFloat, _ align: NSTextAlignment) -> NSTextField {
        let l = L.label(text, size: 7.5, color: Theme.textFaint)
        l.alignment = align
        if width > 0 { l.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return l
    }

    private func reload() {
        let app = AppState.shared

        autoButton.title = app.buyPointAutoEnabled ? "自动：开" : "自动：关"
        autoButton.contentTintColor = app.buyPointAutoEnabled ? Theme.accent : Theme.textFaint

        if app.isBuyPointScanning {
            statusLabel.stringValue = "扫描中…"
            statusLabel.textColor = Theme.accent
        } else {
            statusLabel.stringValue = app.buyPointStatus
            statusLabel.textColor = Theme.textFaint
        }

        let entries = Array(app.buyPointEntries.prefix(maxRows))
        hintLabel.isHidden = !entries.isEmpty || app.isBuyPointScanning
        // 首条触发的完整依据（行内只放得下触发类型）
        if let first = entries.first {
            reasonLabel.stringValue = "依据：\(first.trigger.reason)"
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
}

// MARK: - 买点榜行

final class BuyPointBoardRow: NSView {
    var onSelect: ((Security) -> Void)?

    private let dotLabel = L.label("", size: 8, color: Theme.up)
    private let nameLabel = L.label("", size: 8.5, weight: .medium)
    private let priceLabel = L.label("", size: 8, color: Theme.text, mono: true)
    private let changeLabel = L.label("", size: 8, mono: true)
    private let triggerLabel = L.label("", size: 8, weight: .medium)
    private let timeLabel = L.label("", size: 8, color: Theme.textDim, mono: true)
    private let supportLabel = L.label("", size: 8, color: Theme.textDim, mono: true)
    private var entry: BuyPointEntry?

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
        triggerLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        timeLabel.alignment = .right
        timeLabel.widthAnchor.constraint(equalToConstant: 32).isActive = true
        supportLabel.alignment = .right
        supportLabel.widthAnchor.constraint(equalToConstant: 62).isActive = true

        let row = L.hstack([dotLabel, nameLabel, priceLabel, changeLabel,
                            triggerLabel, timeLabel, supportLabel], spacing: 3)
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

    func configure(_ e: BuyPointEntry) {
        entry = e

        // 新触发高亮：红点 + 底色
        dotLabel.stringValue = e.isNew ? "●" : ""
        layer?.backgroundColor = e.isNew
            ? Theme.buy.withAlphaComponent(0.09).cgColor
            : NSColor.clear.cgColor

        nameLabel.stringValue = e.security.name.isEmpty ? e.security.displayCode : e.security.name
        nameLabel.textColor = e.isNew ? Theme.text : Theme.textDim
        priceLabel.stringValue = Fmt.price(e.price)
        changeLabel.stringValue = Fmt.pct(e.changePct, decimals: 1)
        changeLabel.textColor = Theme.color(change: e.changePct)

        // 触发：买卖方向 + 类型（买红卖绿，与分时图标记同色）
        let dir = e.trigger.direction.shortLabel
        triggerLabel.stringValue = "\(dir) \(e.trigger.kind.label)"
        triggerLabel.textColor = e.trigger.direction == .buy ? Theme.up : Theme.down

        timeLabel.stringValue = Fmt.intradayFormatter.string(from: e.firstSeenAt)

        if let s = e.support {
            if let d = e.distanceToSupportPct {
                supportLabel.stringValue = "撑 \(Fmt.price(s)) \(Fmt.pct(-d, decimals: 1))"
            } else {
                supportLabel.stringValue = "撑 \(Fmt.price(s))"
            }
        } else {
            supportLabel.stringValue = "撑 —"
        }
    }
}
