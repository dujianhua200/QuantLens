import AppKit

// MARK: - 集合竞价榜单（底部版）

/// 底部专用竞价选股榜单。比右栏精简版显示更多字段：
/// 排名 / 名称代码 / 高开幅度 / 大涨概率 / 量能 / 竞价额 / 换手 / 行业。
/// 数据来源与右栏面板一致（AppState.auctionState）。
final class AuctionBoardPanel: PanelBase {

    private let body = FlippedStackView()
    private var rows: [AuctionBoardRow] = []
    private let statusLabel = L.label("", size: 8, color: Theme.textFaint)
    private let phaseLabel = L.label("", size: 8, weight: .semibold, color: Theme.textDim)
    private let scanButton = NSButton()

    private let maxRows = 8
    private var observer: NSObjectProtocol?

    init() {
        super.init(title: "集合竞价选股", icon: "chart.bar.doc.horizontal")

        // 顶部：阶段 + 扫描按钮
        phaseLabel.wantsLayer = true
        phaseLabel.alignment = .center

        scanButton.title = "立即扫描"
        scanButton.isBordered = false
        scanButton.bezelStyle = .inline
        scanButton.font = Fonts.ui(8, weight: .medium)
        scanButton.contentTintColor = Theme.accent
        scanButton.target = self
        scanButton.action = #selector(onScan)
        scanButton.setContentHuggingPriority(.required, for: .horizontal)

        let headRow = L.hstack([phaseLabel, L.spacer(), scanButton], spacing: 6)
        addBody(headRow)
        headRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        // 表头
        // 列宽按内容实际需要分配：名字固定 42pt（够 4 字中文），
        // 剩余空间平均分给数值列，避免右侧留白
        let header = L.hstack([
            colLabel("#", 14, .right),
            colLabel("名称", 40, .left),
            colLabel("高开", 46, .right),
            colLabel("大涨", 38, .right),
            colLabel("量能", 34, .right),
            colLabel("竞价额", 46, .right),
            colLabel("换手", 44, .right)
        ], spacing: 4)
        addBody(header)
        header.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        // 列表
        body.orientation = .vertical
        body.spacing = 1
        body.alignment = .leading
        body.distribution = .fill
        body.translatesAutoresizingMaskIntoConstraints = false

        for _ in 0..<maxRows {
            let row = AuctionBoardRow()
            row.isHidden = true
            row.onSelect = { pick in
                AppState.shared.selectAuctionPick(pick)
            }
            rows.append(row)
            body.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 15).isActive = true
        }

        addBody(body)
        body.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        statusLabel.stringValue = "09:15 自动开始 · 09:25 出结果"
        addBody(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        observer = NotificationCenter.default.addObserver(
            forName: AppState.didChangeAuction, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
    }

    private func colLabel(_ text: String, _ width: CGFloat, _ align: NSTextAlignment) -> NSTextField {
        let l = L.label(text, size: 7.5, color: Theme.textFaint)
        l.alignment = align
        if width > 0 { l.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return l
    }

    private func reload() {
        let st = AppState.shared.auctionState
        let phase = AppState.shared.auctionPhase

        phaseLabel.stringValue = " " + phase.rawValue + " "
        let pc: NSColor
        switch phase {
        case .locked: pc = Theme.up
        case .earlyNoisy: pc = Theme.risk
        case .settled: pc = Theme.accent
        default: pc = Theme.textDim
        }
        phaseLabel.textColor = pc
        phaseLabel.layer?.backgroundColor = pc.withAlphaComponent(0.13).cgColor
        phaseLabel.layer?.cornerRadius = 3

        let picks = st.picks
        for (i, row) in rows.enumerated() {
            if i < picks.count {
                row.update(pick: picks[i], rank: i + 1)
                row.isHidden = false
            } else {
                row.isHidden = true
            }
        }

        var s = st.message.isEmpty ? phase.hint : st.message
        if st.candidates > 0 {
            s += "  ·  候选 \(st.candidates) 采样 \(st.scanned)"
        }
        statusLabel.stringValue = s
    }

    @objc private func onScan() {
        Task { @MainActor in
            await AppState.shared.auctionScanNow()
        }
    }
}

// MARK: - 榜单行

final class AuctionBoardRow: NSView {

    private let rankLabel = L.label("", size: 7.5, color: Theme.textFaint, mono: true)
    private let nameLabel = L.label("", size: 8.5, weight: .medium)
    private let gapLabel = L.label("", size: 9, weight: .semibold, mono: true)
    private let surgeLabel = L.label("", size: 8.5, weight: .semibold, mono: true)
    private let volLabel = L.label("", size: 8, color: Theme.textDim, mono: true)
    private let amountLabel = L.label("", size: 8, color: Theme.textDim, mono: true)
    private let turnoverLabel = L.label("", size: 8, color: Theme.textDim, mono: true)

    private var pick: AuctionPick?
    var onSelect: ((AuctionPick) -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        rankLabel.alignment = .right
        rankLabel.widthAnchor.constraint(equalToConstant: 14).isActive = true

        nameLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        gapLabel.alignment = .right
        gapLabel.widthAnchor.constraint(equalToConstant: 46).isActive = true

        surgeLabel.alignment = .right
        surgeLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true

        volLabel.alignment = .right
        volLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true

        amountLabel.alignment = .right
        amountLabel.widthAnchor.constraint(equalToConstant: 46).isActive = true

        turnoverLabel.alignment = .right
        turnoverLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        // 关键：所有文本标签都不参与鼠标事件命中，
        // 否则点击会落在 NSTextField 上，行视图的 mouseDown 永远收不到。
        for lb in [rankLabel, nameLabel, gapLabel, surgeLabel, volLabel, amountLabel, turnoverLabel] {
            lb.isSelectable = false
            lb.isEditable = false
        }

        // 所有列固定宽度，禁止压缩，确保每列都完整显示
        for lb in [rankLabel, nameLabel, gapLabel, surgeLabel, volLabel, amountLabel, turnoverLabel] {
            lb.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let row = L.hstack([rankLabel, nameLabel, gapLabel, surgeLabel, volLabel, amountLabel, turnoverLabel], spacing: 4)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func update(pick: AuctionPick, rank: Int) {
        self.pick = pick
        rankLabel.stringValue = "\(rank)"
        nameLabel.stringValue = pick.name

        gapLabel.stringValue = String(format: "%+.2f%%", pick.gapPct)
        gapLabel.textColor = pick.gapPct >= 0 ? Theme.up : Theme.down

        surgeLabel.stringValue = String(format: "%.0f%%", pick.surgeProbability)
        switch pick.surgeProbability {
        case 45...: surgeLabel.textColor = Theme.up
        case 30..<45: surgeLabel.textColor = Theme.risk
        case 18..<30: surgeLabel.textColor = Theme.accent
        default: surgeLabel.textColor = Theme.textDim
        }

        // 量能：量比优先，缺失用换手
        if pick.volumeRatio > 0 {
            volLabel.stringValue = String(format: "%.1f", pick.volumeRatio)
        } else if pick.turnover > 0 {
            volLabel.stringValue = String(format: "%.1f", pick.turnover)
        } else {
            volLabel.stringValue = "—"
        }

        amountLabel.stringValue = pick.amount >= 1e8
            ? String(format: "%.1f亿", pick.amountInYi)
            : String(format: "%.0f万", pick.amount / 1e4)

        turnoverLabel.stringValue = pick.turnover > 0
            ? String(format: "%.2f%%", pick.turnover)
            : "—"

        layer?.backgroundColor = pick.grade == "重点"
            ? Theme.up.withAlphaComponent(0.09).cgColor
            : NSColor.clear.cgColor

        toolTip = String(format: "%@ %@ · %@ · 竞价额 %.2f亿 · 流通 %.0f亿 · 稳定性 %.2f · 评分 %.0f",
                         pick.name, pick.security.displayCode, pick.industry,
                         pick.amountInYi, pick.floatCap, pick.stability, pick.score)
        needsDisplay = true
    }

    /// 让所有子视图的点击都归到本行，确保「点一下就切图」稳定生效。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let p = pick else { return }
        onSelect?(p)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
