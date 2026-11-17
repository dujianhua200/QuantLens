import AppKit

// MARK: - 行情头部

final class QuoteHeaderView: NSView {

    private let nameLabel = L.label("", size: 19, weight: .semibold)
    private let codeLabel = L.label("", size: 10, color: Theme.textDim, mono: true)
    private let marketLabel = L.label("", size: 8.5, weight: .medium, color: Theme.accent)
    private let priceLabel = L.label("—", size: 32, weight: .light, mono: true)
    private let pctLabel = L.label("—", size: 11, weight: .semibold, mono: true)
    private let changeLabel = L.label("—", size: 11, mono: true)
    private let timeLabel = L.label("", size: 9, color: Theme.textFaint)
    private var metricLabels: [NSTextField] = []
    private var metricTitles: [NSTextField] = []

    private let marketBadge = RoundedBox(frame: .zero)
    private let watchButton = NSButton()
    private var onToggleWatch: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    private func build() {
        marketBadge.fillColor = Theme.accent.withAlphaComponent(0.13)
        marketBadge.borderColor = .clear
        marketBadge.cornerRadius = 3
        marketBadge.translatesAutoresizingMaskIntoConstraints = false
        marketBadge.addSubview(marketLabel)
        marketLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            marketLabel.topAnchor.constraint(equalTo: marketBadge.topAnchor, constant: 1.5),
            marketLabel.bottomAnchor.constraint(equalTo: marketBadge.bottomAnchor, constant: -1.5),
            marketLabel.leadingAnchor.constraint(equalTo: marketBadge.leadingAnchor, constant: 5),
            marketLabel.trailingAnchor.constraint(equalTo: marketBadge.trailingAnchor, constant: -5)
        ])

        let badge2 = RoundedBox(frame: .zero)
        badge2.fillColor = Theme.panel2
        badge2.borderColor = .clear
        badge2.cornerRadius = 3
        badge2.translatesAutoresizingMaskIntoConstraints = false
        badge2.addSubview(codeLabel)
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            codeLabel.topAnchor.constraint(equalTo: badge2.topAnchor, constant: 1.5),
            codeLabel.bottomAnchor.constraint(equalTo: badge2.bottomAnchor, constant: -1.5),
            codeLabel.leadingAnchor.constraint(equalTo: badge2.leadingAnchor, constant: 5),
            codeLabel.trailingAnchor.constraint(equalTo: badge2.trailingAnchor, constant: -5)
        ])

        // 自选按钮：当前标的不在自选时显示「+ 自选」，已自选显示「★ 已自选」
        watchButton.setButtonType(.momentaryChange)
        watchButton.isBordered = false
        watchButton.wantsLayer = true
        watchButton.layer?.cornerRadius = 3
        watchButton.target = self
        watchButton.action = #selector(watchTapped)
        watchButton.translatesAutoresizingMaskIntoConstraints = false
        watchButton.heightAnchor.constraint(equalToConstant: 17).isActive = true
        watchButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true

        // 名称行不放 spacer（spacer 会抢走宽度导致名称被截断）
        let titleRow = L.hstack([nameLabel, badge2, marketBadge, watchButton], spacing: 7)
        titleRow.setContentCompressionResistancePriority(.required, for: .horizontal)
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        // 名称绝不允许压缩成「贵…」，它是这一行最重要的信息
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        nameLabel.lineBreakMode = .byClipping
        badge2.setContentHuggingPriority(.required, for: .horizontal)
        badge2.setContentCompressionResistancePriority(.required, for: .horizontal)
        marketBadge.setContentHuggingPriority(.required, for: .horizontal)
        marketBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        watchButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let changeRow = L.hstack([pctLabel, changeLabel, timeLabel], spacing: 8)
        pctLabel.setContentHuggingPriority(.required, for: .horizontal)
        changeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let left = L.vstack([titleRow, changeRow], spacing: 3)
        left.alignment = .leading
        // 锁死宽度：名称行最长约「贵州茅台 600519 沪A ★已自选」，200pt 足够。
        // 不锁的话 stack 会把空间分给左侧，把现价推到中间形成断层。
        // 左侧信息块锁定最小宽度：「贵州茅台 600519 沪A ★已自选」约 250pt
        left.setContentHuggingPriority(.required, for: .horizontal)
        left.setContentCompressionResistancePriority(.required, for: .horizontal)
        // 固定而非下限：stack 会忽略 greaterThanOrEqual，必须用 equal
        left.widthAnchor.constraint(equalToConstant: 268).isActive = true

        priceLabel.setContentHuggingPriority(.required, for: .horizontal)
        priceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        priceLabel.lineBreakMode = .byClipping

        // 指标网格：7 项横向等分铺满，不再挤在右侧
        let cols: [(String, String)] = [
            ("今开", "open"), ("最高", "high"), ("最低", "low"),
            ("成交额", "amount"), ("换手", "turnover"),
            ("市值", "cap"), ("PE", "pe")
        ]
        var metricViews: [NSView] = []
        for col in cols {
            let title = L.label(col.0, size: 8.5, color: Theme.textDim)
            let value = L.label("—", size: 10.5, color: Theme.text, mono: true)
            value.alignment = .left

            // 关键：列内文本必须允许压缩到等分宽度，
            // 否则内容宽度会压过「各列等宽」约束，把整条指标撑超出右边界。
            for lb in [title, value] {
                lb.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                lb.setContentHuggingPriority(.defaultLow, for: .horizontal)
            }

            let v = L.vstack([title, value], spacing: 2)
            v.alignment = .leading
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // 每列等宽，撑开后由 stack 的 distribution 均分
            // 宽度由 fillEqually 统一分配，无需单独约束
            metricViews.append(v)
            metricTitles.append(title)
            metricLabels.append(value)
        }

        // 指标条：等分铺满，各列之间自动留白
        // 左侧信息块（不含现价）。现价单独作为顶级视图，避免被 hstack 压缩。
        let leftGroup = left
        leftGroup.setContentHuggingPriority(.required, for: .horizontal)
        leftGroup.setContentCompressionResistancePriority(.required, for: .horizontal)

        // 用纯 NSView + 手写约束实现严格的 7 等分栅格。
        // NSStackView 会自行管理子视图宽度，与手动等宽约束冲突，
        // 因此这里完全绕开 stack，直接铺约束。
        let metricsRow = NSView()
        metricsRow.translatesAutoresizingMaskIntoConstraints = false
        metricsRow.setContentHuggingPriority(.init(1), for: .horizontal)
        metricsRow.setContentCompressionResistancePriority(.required, for: .horizontal)


        // 指标列：按各自内容宽度排布，间距 16pt，整体右对齐
        var prevMetric: NSView?
        for v in metricViews {
            metricsRow.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: metricsRow.topAnchor),
                v.bottomAnchor.constraint(equalTo: metricsRow.bottomAnchor),
                // 宽度按内容，限制在 68~96pt 之间
                v.widthAnchor.constraint(greaterThanOrEqualToConstant: 68),
                v.widthAnchor.constraint(lessThanOrEqualToConstant: 96)
            ])
            if let prev = prevMetric {
                v.leadingAnchor.constraint(equalTo: prev.trailingAnchor, constant: 16).isActive = true
            } else {
                v.leadingAnchor.constraint(equalTo: metricsRow.leadingAnchor).isActive = true
            }
            prevMetric = v
        }
        // 最后一列贴住指标区右边界
        if let last = prevMetric {
            last.trailingAnchor.constraint(equalTo: metricsRow.trailingAnchor).isActive = true
        }

        // 现价之后插入固定宽的间隔，视觉上把「价格」与「指标条」彻底分开，
        // 间距取约一个指标列宽的一半，既分明又不浪费空间。
        let priceGap = NSView()
        priceGap.translatesAutoresizingMaskIntoConstraints = false
        priceGap.widthAnchor.constraint(equalToConstant: 46).isActive = true

        // 手工布局：leftGroup / priceGap / metricsRow 三个视图直接约束，
        // 绕开 NSStackView 的宽度分配，确保指标条精确铺到右边界。
        addSubview(leftGroup)
        addSubview(priceLabel)
        addSubview(priceGap)
        addSubview(metricsRow)
        leftGroup.translatesAutoresizingMaskIntoConstraints = false
        priceLabel.translatesAutoresizingMaskIntoConstraints = false
        priceGap.translatesAutoresizingMaskIntoConstraints = false
        metricsRow.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            leftGroup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            leftGroup.centerYAnchor.constraint(equalTo: centerYAnchor),

            // 现价紧贴左侧信息块之后，宽度由文本自身决定，绝不压缩
            priceLabel.leadingAnchor.constraint(equalTo: leftGroup.trailingAnchor, constant: 16),
            priceLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            priceLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 152),

            priceGap.leadingAnchor.constraint(equalTo: priceLabel.trailingAnchor, constant: 16),
            priceGap.centerYAnchor.constraint(equalTo: centerYAnchor),

            metricsRow.leadingAnchor.constraint(greaterThanOrEqualTo: priceGap.trailingAnchor),
            metricsRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            metricsRow.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            metricsRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        // 现价固定自身宽度，指标条吃掉剩余空间
        // 现价锁死自身宽度；指标条吃满剩余空间
        priceLabel.setContentHuggingPriority(.required, for: .horizontal)
        priceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        priceLabel.lineBreakMode = .byClipping
        // 指标条必须吃掉全部剩余宽度，否则右侧会出现空尾
        metricsRow.setContentHuggingPriority(.init(1), for: .horizontal)
        metricsRow.setContentCompressionResistancePriority(.required, for: .horizontal)

    }

    func setWatchHandler(_ handler: @escaping () -> Void) {
        onToggleWatch = handler
    }

    @objc private func watchTapped() {
        onToggleWatch?()
    }

    func refresh() {
        let app = AppState.shared
        guard let sec = app.selected else { return }

        // 自选状态
        let inList = app.isCurrentInWatchlist
        let title = inList ? "★ 已自选" : "+ 自选"
        let watchColor = inList ? Theme.risk : Theme.buy
        watchButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Fonts.ui(9, weight: .semibold), .foregroundColor: watchColor
        ])
        watchButton.layer?.backgroundColor = watchColor.withAlphaComponent(0.16).cgColor
        watchButton.toolTip = nil
        let q = app.selectedQuote ?? app.data?.quote

        nameLabel.stringValue = sec.name.isEmpty ? sec.displayCode : sec.name
        codeLabel.stringValue = sec.displayCode
        marketLabel.stringValue = sec.market.label

        guard let q else {
            priceLabel.stringValue = "—"
            pctLabel.stringValue = "—"
            changeLabel.stringValue = ""
            timeLabel.stringValue = ""
            for l in metricLabels { l.stringValue = "—" }
            return
        }

        let decimals = q.price >= 10 ? 2 : 3
        priceLabel.stringValue = Fmt.price(q.price, decimals: decimals)
        let color = Theme.color(change: q.changePct)
        priceLabel.textColor = color
        pctLabel.stringValue = Fmt.pct(q.changePct)
        pctLabel.textColor = color
        changeLabel.stringValue = String(format: "%+.2f", q.change)
        changeLabel.textColor = color
        timeLabel.stringValue = "更新 \(Fmt.intradayFormatter.string(from: q.timestamp))"

        let values = [
            Fmt.price(q.open, decimals: decimals),
            Fmt.price(q.high, decimals: decimals),
            Fmt.price(q.low, decimals: decimals),
            Fmt.money(q.amount),
            Fmt.pct(q.turnoverRate, sign: false),
            q.totalMarketCap > 0 ? String(format: "%.0f亿", q.totalMarketCap) : "—",
            q.pe > 0 ? Fmt.price(q.pe, decimals: 1) : "—"
        ]
        for (i, v) in values.enumerated() where i < metricLabels.count {
            metricLabels[i].stringValue = v
        }
        metricLabels[1].textColor = Theme.up.withAlphaComponent(0.9)
        metricLabels[2].textColor = Theme.down.withAlphaComponent(0.9)
    }
}

// MARK: - 周期/指标切换栏

final class ToolbarRow: NSView {

    private let intradayButton = NSButton()
    private var periodButtons: [KPeriod: NSButton] = [:]
    private var subButtons: [SubIndicator: NSButton] = [:]
    private let maButton = NSButton()
    private let bollButton = NSButton()
    private let levelButton = NSButton()
    private let markerButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    private func chip(_ title: String, action: Selector, tag: Int = 0) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.setButtonType(.momentaryChange)
        b.isBordered = false
        b.font = Fonts.ui(10)
        b.contentTintColor = Theme.textDim
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Fonts.ui(10), .foregroundColor: Theme.textDim
        ])
        b.wantsLayer = true
        b.layer?.cornerRadius = 4
        b.tag = tag
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return b
    }

    private func build() {
        // 分时 / K线 切换
        intradayButton.title = "分时"
        intradayButton.setButtonType(.toggle)
        intradayButton.isBordered = false
        intradayButton.font = Fonts.ui(10)
        intradayButton.target = self
        intradayButton.action = #selector(toggleIntraday)
        intradayButton.wantsLayer = true
        intradayButton.layer?.cornerRadius = 4
        intradayButton.translatesAutoresizingMaskIntoConstraints = false
        intradayButton.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let periodSep = NSView()
        periodSep.wantsLayer = true
        periodSep.layer?.backgroundColor = Theme.border.cgColor
        periodSep.translatesAutoresizingMaskIntoConstraints = false
        periodSep.widthAnchor.constraint(equalToConstant: 0.6).isActive = true
        periodSep.heightAnchor.constraint(equalToConstant: 12).isActive = true

        var periodViews: [NSView] = [intradayButton, periodSep]
        for p in KPeriod.allCases {
            let b = chip(p.label, action: #selector(periodTapped(_:)))
            b.tag = KPeriod.allCases.firstIndex(of: p) ?? 0
            periodButtons[p] = b
            periodViews.append(b)
        }

        var subViews: [NSView] = []
        for s in SubIndicator.allCases {
            let b = chip(s.label, action: #selector(subTapped(_:)))
            b.tag = SubIndicator.allCases.firstIndex(of: s) ?? 0
            subButtons[s] = b
            subViews.append(b)
        }

        for (b, title, action) in [(maButton, "均线", #selector(toggleMA)),
                                   (bollButton, "BOLL", #selector(toggleBoll)),
                                   (levelButton, "支撑压力", #selector(toggleLevels)),
                                   (markerButton, "信号标记", #selector(toggleMarkers))] {
            b.title = title
            b.setButtonType(.toggle)
            b.isBordered = false
            b.font = Fonts.ui(10)
            b.target = self
            b.action = action
            b.wantsLayer = true
            b.layer?.cornerRadius = 4
            b.translatesAutoresizingMaskIntoConstraints = false
            b.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }

        let left = L.hstack(periodViews, spacing: 1)
        let sep1 = makeSep()
        let mid = L.hstack(subViews, spacing: 1)
        let sep2 = makeSep()
        let right = L.hstack([maButton, bollButton, levelButton, markerButton], spacing: 1)

        let row = L.hstack([left, sep1, mid, sep2, right, L.spacer()], spacing: 8)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10)
        ])
        updateStates()
    }

    private func makeSep() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.border.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 0.6).isActive = true
        v.heightAnchor.constraint(equalToConstant: 12).isActive = true
        return v
    }

    @objc private func toggleIntraday() {
        let show = !AppState.shared.showIntraday
        AppState.shared.toggleIntraday(show)
        updateStates()
    }

    @objc private func periodTapped(_ sender: NSButton) {
        // 点周期按钮时自动切回 K 线
        if AppState.shared.showIntraday {
            AppState.shared.toggleIntraday(false)
        }
        let p = KPeriod.allCases[sender.tag]
        AppState.shared.setPeriod(p)
        updateStates()
    }

    @objc private func subTapped(_ sender: NSButton) {
        let s = SubIndicator.allCases[sender.tag]
        AppState.shared.subIndicator = s
        updateStates()
        NotificationCenter.default.post(name: MainWindow.reloadChart, object: nil)
    }

    @objc private func toggleMA() {
        AppState.shared.showMA.toggle()
        updateStates()
        NotificationCenter.default.post(name: MainWindow.reloadChart, object: nil)
    }

    @objc private func toggleBoll() {
        AppState.shared.showBoll.toggle()
        updateStates()
        NotificationCenter.default.post(name: MainWindow.reloadChart, object: nil)
    }

    @objc private func toggleLevels() {
        AppState.shared.showLevels.toggle()
        updateStates()
        NotificationCenter.default.post(name: MainWindow.reloadChart, object: nil)
    }

    @objc private func toggleMarkers() {
        AppState.shared.showMarkers.toggle()
        updateStates()
        NotificationCenter.default.post(name: MainWindow.reloadChart, object: nil)
    }

    func updateStates() {
        let app = AppState.shared

        // 分时按钮
        let showIntraday = app.showIntraday
        intradayButton.attributedTitle = NSAttributedString(string: "分时", attributes: [
            .font: Fonts.ui(10, weight: showIntraday ? .semibold : .regular),
            .foregroundColor: showIntraday ? NSColor.white : Theme.textDim
        ])
        intradayButton.layer?.backgroundColor = showIntraday
            ? Theme.accent.withAlphaComponent(0.28).cgColor
            : NSColor.clear.cgColor
        for (p, b) in periodButtons {
            let active = (app.period == p) && !showIntraday
            style(b, active: active, color: Theme.accent)
        }
        for (s, b) in subButtons {
            style(b, active: app.subIndicator == s, color: Theme.accent)
        }
        style(maButton, active: app.showMA, color: Theme.ma5)
        style(bollButton, active: app.showBoll, color: Theme.accent)
        style(levelButton, active: app.showLevels, color: Theme.buy)
        style(markerButton, active: app.showMarkers, color: Theme.risk)
    }

    private func style(_ b: NSButton, active: Bool, color: NSColor) {
        b.attributedTitle = NSAttributedString(string: b.title, attributes: [
            .font: Fonts.ui(10, weight: active ? .semibold : .regular),
            .foregroundColor: active ? NSColor.white : Theme.textDim
        ])
        b.layer?.backgroundColor = active ? color.withAlphaComponent(0.24).cgColor : NSColor.clear.cgColor
    }
}
