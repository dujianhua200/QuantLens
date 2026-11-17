import AppKit

// MARK: - 战法识别面板

/// 展示当前标的命中的短线战法，以及回测胜率参考。
final class StrategyPanel: PanelBase {

    private let body = FlippedStackView()
    private var rows: [StrategyRow] = []
    private let statusLabel = L.label("", size: 8, color: Theme.textFaint)
    private let backtestButton = NSButton()

    private let maxRows = 7
    private var observer: NSObjectProtocol?

    init() {
        super.init(title: "实证买卖点", icon: "chart.line.uptrend.xyaxis")

        backtestButton.title = "回测"
        backtestButton.isBordered = false
        backtestButton.bezelStyle = .inline
        backtestButton.font = Fonts.ui(8, weight: .medium)
        backtestButton.contentTintColor = Theme.accent
        backtestButton.target = self
        backtestButton.action = #selector(onBacktest)
        addHeaderAccessory(backtestButton)

        body.orientation = .vertical
        body.spacing = 2
        body.alignment = .leading
        body.distribution = .fill
        body.translatesAutoresizingMaskIntoConstraints = false

        for _ in 0..<maxRows {
            let row = StrategyRow()
            row.isHidden = true
            rows.append(row)
            body.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        addBody(body)
        body.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        statusLabel.stringValue = "点「回测」验证战法胜率"
        addBody(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        observer = NotificationCenter.default.addObserver(
            forName: AppState.didChangeStrategy, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
    }

    private func reload() {
        let app = AppState.shared

        if app.isBacktesting {
            statusLabel.stringValue = "回测中，拉取历史数据…"
            return
        }

        // 优先显示实证信号（有K线时）
        if let d = app.data, d.candles.count >= 65 {
            let assess = EmpiricalSignals.assess(candles: d.candles)
            var list = assess.findings
            // 补齐未触发的，便于看到全部实测规律
            for f in EmpiricalSignals.catalog where !list.contains(where: { $0.id == f.id }) {
                var g = f; g.triggered = false; list.append(g)
            }
            list.sort { a, b in
                if a.triggered != b.triggered { return a.triggered }
                return a.edge < b.edge
            }
            for (i, row) in rows.enumerated() {
                if i < list.count { row.updateEmpirical(list[i]); row.isHidden = false }
                else { row.isHidden = true }
            }
            statusLabel.stringValue = assess.headline
            statusLabel.textColor = assess.worstLevel == .strongAvoid ? Theme.down
                : (assess.worstLevel == .avoid ? Theme.risk : Theme.textFaint)
            return
        }

        // 优先显示回测统计（有数据时）
        if !app.backtestStats.isEmpty {
            for (i, row) in rows.enumerated() {
                if i < app.backtestStats.count {
                    row.update(stat: app.backtestStats[i])
                    row.isHidden = false
                } else {
                    row.isHidden = true
                }
            }
            statusLabel.stringValue = String(format:"基准 %+.2f%% · 按5日胜率排序", StrategyBacktest.marketBaseline5D)
            statusLabel.textColor = Theme.textFaint
            return
        }

        guard let result = app.strategyResult else {
            rows.forEach { $0.isHidden = true }
            statusLabel.stringValue = "点「回测」验证战法胜率"
            return
        }

        // 显示命中的战法（未命中的也列，便于了解状态）
        let list = result.matches
        for (i, row) in rows.enumerated() {
            if i < list.count {
                row.update(match: list[i])
                row.isHidden = false
            } else {
                row.isHidden = true
            }
        }
        statusLabel.stringValue = result.summary
        statusLabel.textColor = result.netBias > 0 ? Theme.up : (result.netBias < 0 ? Theme.down : Theme.textFaint)
    }

    @objc private func onBacktest() {
        Task { @MainActor in
            await AppState.shared.runStrategyBacktest()
        }
    }
}

// MARK: - 战法行

final class StrategyRow: NSView {

    private let nameLabel = L.label("", size: 8.5, weight: .medium)
    private let badge = L.label("", size: 7, weight: .semibold, color: .white)
    private let strengthLabel = L.label("", size: 8, color: Theme.textDim, mono: true)
    private let detailLabel = L.label("", size: 7.5, color: Theme.textFaint)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        nameLabel.widthAnchor.constraint(equalToConstant: 74).isActive = true
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 2
        badge.widthAnchor.constraint(equalToConstant: 30).isActive = true

        strengthLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        strengthLabel.alignment = .right

        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let top = L.hstack([nameLabel, badge, strengthLabel, detailLabel], spacing: 5)
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

    /// 显示战法命中状态
    func update(match: StrategySignals.Match) {
        nameLabel.stringValue = match.name
        nameLabel.textColor = match.hit ? Theme.text : Theme.textFaint

        if match.hit {
            badge.stringValue = match.bias == .buy ? "买" : (match.bias == .sell ? "卖" : "中")
            let c: NSColor = match.bias == .buy ? Theme.up : (match.bias == .sell ? Theme.down : Theme.textDim)
            badge.layer?.backgroundColor = c.withAlphaComponent(0.75).cgColor
            strengthLabel.stringValue = "\(Int(match.strength))"
            strengthLabel.textColor = c
        } else {
            badge.stringValue = "—"
            badge.layer?.backgroundColor = Theme.panel3.cgColor
            strengthLabel.stringValue = ""
        }

        // 若该战法已用全市场数据验证，标注实测结论
        if let v = StrategyBacktest.verified[match.id] {
            let mark = v.tStat < -1.96 ? "✗" : (v.tStat > 1.96 ? "✓" : "≈")
            let c: NSColor = v.tStat < -1.96 ? Theme.down : (v.tStat > 1.96 ? Theme.up : Theme.textDim)
            detailLabel.stringValue = String(format:"%@实测 %+.2f%% · %@", mark, v.edge, v.verdict)
            detailLabel.textColor = c
        } else {
            detailLabel.stringValue = match.detail
            detailLabel.textColor = Theme.textFaint
        }
        layer?.backgroundColor = match.hit && match.bias == .buy
            ? Theme.up.withAlphaComponent(0.06).cgColor
            : NSColor.clear.cgColor
    }

    /// 显示实证信号（触发状态 + 实测收益）
    func updateEmpirical(_ f: EmpiricalSignals.Finding) {
        nameLabel.stringValue = f.name
        nameLabel.textColor = f.triggered ? Theme.text : Theme.textFaint

        // 实测超额收益直接作为徽章
        badge.stringValue = String(format: "%+.2f", f.edge)
        let c: NSColor = f.level == .strongAvoid ? Theme.down
            : (f.level == .avoid ? Theme.risk
               : (f.level == .weakFavor ? Theme.up : Theme.textDim))
        badge.layer?.backgroundColor = c.withAlphaComponent(f.triggered ? 0.85 : 0.3).cgColor

        strengthLabel.stringValue = String(format: "t=%.1f", f.tStat)
        strengthLabel.textColor = f.triggered ? c : Theme.textFaint

        detailLabel.stringValue = f.triggered ? "已触发" : "未触发"
        detailLabel.textColor = f.triggered ? c : Theme.textFaint

        layer?.backgroundColor = f.triggered && f.level == .strongAvoid
            ? Theme.down.withAlphaComponent(0.08).cgColor : NSColor.clear.cgColor
    }

    /// 显示回测统计
    func update(stat: StrategyBacktest.Stat) {
        nameLabel.stringValue = stat.name
        nameLabel.textColor = Theme.text

        let win = stat.winRate5D
        badge.stringValue = String(format: "%.0f%%", win)
        let c: NSColor = win >= 55 ? Theme.up : (win >= 45 ? Theme.risk : Theme.down)
        badge.layer?.backgroundColor = c.withAlphaComponent(0.7).cgColor

        strengthLabel.stringValue = "\(stat.signalCount)次"
        strengthLabel.textColor = Theme.textDim

        detailLabel.stringValue = String(format: "5日 %+.2f%%", stat.avgRet5D)
        detailLabel.textColor = stat.avgRet5D > 0 ? Theme.up : Theme.down
    }
}
