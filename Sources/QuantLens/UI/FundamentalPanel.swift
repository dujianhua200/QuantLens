import AppKit

// MARK: - 基本面选股面板

/// 用实证因子（市值/PB/PE）对自选股排序。
/// 与「实证买卖点」面板互补：买卖点管短期风险，本面板管中期选股。
final class FundamentalPanel: PanelBase {

    private let body = FlippedStackView()
    private var rows: [FundamentalRow] = []
    private let statusLabel = L.label("", size: 7.5, color: Theme.textFaint)
    private let refreshButton = NSButton()
    private let maxRows = 10
    private var observer: NSObjectProtocol?

    init() {
        super.init(title: "基本面选股", icon: "square.grid.2x2")

        refreshButton.title = "排序"
        refreshButton.isBordered = false
        refreshButton.bezelStyle = .inline
        refreshButton.font = Fonts.ui(8, weight: .medium)
        refreshButton.contentTintColor = Theme.accent
        refreshButton.target = self
        refreshButton.action = #selector(onRank)
        addHeaderAccessory(refreshButton)

        body.orientation = .vertical
        body.spacing = 2
        body.alignment = .leading
        body.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<maxRows {
            let r = FundamentalRow()
            r.isHidden = true
            rows.append(r)
            body.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        addBody(body)
        body.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        statusLabel.stringValue = "市值/PB/PE 实证因子 · 月频 t=17~52"
        addBody(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        observer = NotificationCenter.default.addObserver(
            forName: AppState.didChangeFundamental, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    private func reload() {
        let scores = AppState.shared.fundamentalScores
        guard !scores.isEmpty else {
            rows.forEach { $0.isHidden = true }
            statusLabel.stringValue = "点「排序」按实证因子给自选股打分"
            return
        }
        for (i, row) in rows.enumerated() {
            if i < scores.count { row.update(scores[i], rank: i + 1); row.isHidden = false }
            else { row.isHidden = true }
        }
        let q = scores.filter(\.isDoubleQualified).count
        statusLabel.stringValue = "双因子达标 \(q) 只 · 小市值+低PB 历史月超额 +3~4%"
    }

    @objc private func onRank() {
        AppState.shared.rankWatchlistByFundamentals()
    }
}

// MARK: - 排名行

final class FundamentalRow: NSView {
    private let rankLabel = L.label("", size: 8, color: Theme.textFaint, mono: true)
    private let nameLabel = L.label("", size: 8.5, weight: .medium)
    private let scoreLabel = L.label("", size: 8.5, weight: .semibold, mono: true)
    private let detailLabel = L.label("", size: 7.5, color: Theme.textDim)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        rankLabel.widthAnchor.constraint(equalToConstant: 18).isActive = true
        nameLabel.widthAnchor.constraint(equalToConstant: 62).isActive = true
        nameLabel.lineBreakMode = .byTruncatingTail
        scoreLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true
        scoreLabel.alignment = .right
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let top = L.hstack([rankLabel, nameLabel, scoreLabel, detailLabel], spacing: 4)
        top.translatesAutoresizingMaskIntoConstraints = false
        addSubview(top)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            top.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            top.leadingAnchor.constraint(equalTo: leadingAnchor),
            top.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 15)
        ])
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func update(_ s: FundamentalSelector.Score, rank: Int) {
        rankLabel.stringValue = "\(rank)."
        nameLabel.stringValue = s.name
        scoreLabel.stringValue = String(format: "%.0f", s.total)

        let c: NSColor = s.isDoubleQualified ? Theme.up : (s.total >= 70 ? Theme.accent : Theme.textDim)
        scoreLabel.textColor = c
        nameLabel.textColor = s.isDoubleQualified ? Theme.text : Theme.textDim

        let mark = s.isDoubleQualified ? " ✓✓" : ""
        detailLabel.stringValue = String(format: "%.0f亿 PB%.1f PE%.0f%@", s.mcap, s.pb, s.pe, mark)
        detailLabel.textColor = s.isDoubleQualified ? Theme.up : Theme.textFaint
    }
}
