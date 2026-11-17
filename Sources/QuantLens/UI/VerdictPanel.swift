import AppKit

// MARK: - 智能分析结论面板

/// 展示本地引擎的走势研判结果：结论、信心、买卖价位、依据、风险。
/// 数据来自 `AppState.localVerdict`，点击顶部「🧠 AI 分析」触发。
final class VerdictPanel: RoundedBox {

    private let actionLabel = L.label("—", size: 13, weight: .bold)
    private let confidenceLabel = L.label("", size: 9, color: Theme.textDim, mono: true)
    private let summaryLabel = L.wrapped("", size: 9, color: Theme.textDim)
    private let buyRow = L.label("", size: 9, mono: true)
    private let sellRow = L.label("", size: 9, mono: true)
    private let stopRow = L.label("", size: 9, mono: true)
    private let reasonsLabel = L.wrapped("", size: 8.5, color: Theme.textFaint)
    private let risksLabel = L.wrapped("", size: 8.5, color: Theme.risk)
    private let emptyLabel = L.label("点击顶部「🧠 AI 分析」研判当前标的", size: 8.5, color: Theme.textFaint)

    private var body: NSStackView!
    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        observer = NotificationCenter.default.addObserver(
            forName: AppState.didChangeLocalVerdict, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
    }

    private func build() {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = Theme.risk.cgColor
        dot.layer?.cornerRadius = 2.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 5).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 5).isActive = true

        let title = L.label("智能研判", size: 11, weight: .semibold)
        let titleRow = L.hstack([dot, title, L.spacer(), confidenceLabel], spacing: 5)

        summaryLabel.preferredMaxLayoutWidth = 300
        reasonsLabel.preferredMaxLayoutWidth = 300
        risksLabel.preferredMaxLayoutWidth = 300

        buyRow.textColor = Theme.up
        sellRow.textColor = Theme.down
        stopRow.textColor = Theme.textDim

        body = L.vstack([
            titleRow,
            L.hstack([actionLabel, L.spacer()], spacing: 4),
            summaryLabel,
            buyRow, sellRow, stopRow,
            reasonsLabel,
            risksLabel,
            emptyLabel
        ], spacing: 4)
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            body.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8)
        ])
        titleRow.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        summaryLabel.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        reasonsLabel.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        risksLabel.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }

    func refresh() {
        guard let v = AppState.shared.localVerdict else {
            actionLabel.stringValue = "—"
            actionLabel.textColor = Theme.textFaint
            confidenceLabel.stringValue = ""
            summaryLabel.stringValue = ""
            buyRow.stringValue = ""
            sellRow.stringValue = ""
            stopRow.stringValue = ""
            reasonsLabel.stringValue = ""
            risksLabel.stringValue = ""
            [buyRow, sellRow, stopRow, summaryLabel, reasonsLabel, risksLabel].forEach { $0.isHidden = true }
            emptyLabel.isHidden = false
            return
        }

        [buyRow, sellRow, stopRow, summaryLabel, reasonsLabel, risksLabel].forEach { $0.isHidden = false }
        emptyLabel.isHidden = true

        actionLabel.stringValue = v.action + "  ·  " + v.scene
        actionLabel.textColor = colorFor(action: v.action)
        confidenceLabel.stringValue = "信心 \(v.confidence)"
        confidenceLabel.textColor = v.confidence >= 62 ? Theme.up : (v.confidence >= 45 ? Theme.risk : Theme.textDim)

        summaryLabel.stringValue = v.summary

        if let b = v.buyZone {
            buyRow.stringValue = String(format: "买入区间  %.2f ~ %.2f", b.low, b.high)
        } else {
            buyRow.stringValue = "买入区间  —"
        }
        if let s = v.sellZone {
            sellRow.stringValue = String(format: "卖出区间  %.2f ~ %.2f", s.low, s.high)
        } else {
            sellRow.stringValue = "卖出区间  —"
        }
        if let st = v.stopLoss {
            stopRow.stringValue = String(format: "止损参考  %.2f", st)
        } else {
            stopRow.stringValue = "止损参考  —"
        }

        reasonsLabel.stringValue = v.reasons.isEmpty ? "" : "· " + v.reasons.joined(separator: "\n· ")
        risksLabel.stringValue = v.risks.isEmpty ? "" : "⚠ " + v.risks.joined(separator: "\n⚠ ")
    }

    private func colorFor(action: String) -> NSColor {
        switch action {
        case "强烈买入": return Theme.up
        case "买入": return Theme.buy
        case "观察": return Theme.risk
        default: return Theme.down
        }
    }
}
