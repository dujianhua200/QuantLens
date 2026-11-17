import AppKit

// MARK: - 基础容器

/// 带圆角背景与描边的面板容器
class RoundedBox: NSView {
    var fillColor: NSColor = Theme.panel { didSet { needsDisplay = true } }
    var borderColor: NSColor = Theme.border { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 8 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.backgroundColor = fillColor.cgColor
        layer?.borderColor = borderColor.cgColor
        layer?.borderWidth = 0.6
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func updateLayer() {
        layer?.cornerRadius = cornerRadius
        layer?.backgroundColor = fillColor.cgColor
        layer?.borderColor = borderColor.cgColor
        layer?.borderWidth = 0.6
    }
}

// MARK: - 滚动容器

/// 翻转坐标容器：AppKit 默认原点在左下，滚动视图需要左上原点才能从顶部开始显示
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 翻转的堆栈视图：垂直排列时第一个子视图位于顶部
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// 把 stack 装进可滚动区域：内容从顶部排列、宽度跟随容器、内容不足时不留白
func makeScrollable(_ stack: NSStackView) -> NSScrollView {
    // documentView 必须先有非零 frame，否则 AutoLayout 首次布局会递归卡死
    let container = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    container.translatesAutoresizingMaskIntoConstraints = false

    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: container.topAnchor),
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
    ])

    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.verticalScrollElasticity = .allowed
    scroll.horizontalScrollElasticity = .none
    scroll.scrollerStyle = .overlay
    scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = container

    container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    container.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor).isActive = true

    // 布局完成后回到顶部
    DispatchQueue.main.async {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    return scroll
}

// MARK: - 标签工厂

enum L {
    static func label(_ text: String, size: CGFloat = 11, weight: NSFont.Weight = .regular,
                      color: NSColor = Theme.text, mono: Bool = false) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = mono ? Fonts.mono(size, weight: weight) : Fonts.ui(size, weight: weight)
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return f
    }

    static func wrapped(_ text: String, size: CGFloat = 10, color: NSColor = Theme.textDim) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = Fonts.ui(size)
        f.textColor = color
        f.isSelectable = false
        f.maximumNumberOfLines = 0
        f.preferredMaxLayoutWidth = 260
        return f
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 4, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = spacing
        s.alignment = alignment
        s.distribution = .fill
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    static func vstack(_ views: [NSView], spacing: CGFloat = 4) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.spacing = spacing
        s.alignment = .leading
        s.distribution = .fill
        s.translatesAutoresizingMaskIntoConstraints = false
        // 允许纵向被容器压缩，但不允许把多余高度分配给某个子视图
        for v in views {
            v.setContentHuggingPriority(.required, for: .vertical)
            v.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        }
        return s
    }

    static func spacer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }
}

// MARK: - 面板基类

class PanelBase: RoundedBox {
    let content = NSStackView()
    private let accessoryHost = NSStackView()

    /// 在标题栏右侧挂控件（按钮等）
    func addHeaderAccessory(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        accessoryHost.addArrangedSubview(view)
    }

    init(title: String, icon: String? = nil, trailing: NSView? = nil) {
        super.init(frame: .zero)
        content.orientation = .vertical
        content.spacing = 5
        content.alignment = .leading
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setContentHuggingPriority(.defaultHigh, for: .vertical)

        // 标题行
        var titleViews: [NSView] = []
        if let icon {
            let iv = NSImageView()
            iv.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            iv.contentTintColor = Theme.textDim
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 11).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 11).isActive = true
            titleViews.append(iv)
        }
        let t = L.label(title, size: 10, weight: .semibold, color: Theme.textDim)
        titleViews.append(t)
        titleViews.append(L.spacer())
        if let trailing { titleViews.append(trailing) }

        accessoryHost.orientation = .horizontal
        accessoryHost.spacing = 4
        accessoryHost.translatesAutoresizingMaskIntoConstraints = false
        titleViews.append(accessoryHost)

        let header = L.hstack(titleViews, spacing: 5)
        content.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            // ≤ 而不是 =：内容不足时面板贴合内容，不强行撑满
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9)
        ])
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func clearBody() {
        // 保留第一个 header
        while content.arrangedSubviews.count > 1 {
            let v = content.arrangedSubviews[1]
            content.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
    }

    func addBody(_ v: NSView) {
        content.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
}

// MARK: - 强度条

class ScoreBarView: NSView {
    var value: Double = 0 { didSet { needsDisplay = true } }
    var barColor: NSColor = Theme.accent { didSet { needsDisplay = true } }
    var barHeight: CGFloat = 3 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: barHeight) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        // 无论被布局系统拉伸到多高，都只画 barHeight 高的一条，且贴底
        let h = min(barHeight, bounds.height)
        let y = bounds.height - h
        g.fillRoundedRect(CGRect(x: 0, y: y, width: bounds.width, height: h), radius: h / 2,
                          color: NSColor.white.withAlphaComponent(0.07))
        let w = bounds.width * CGFloat(min(max(value / 100, 0), 1))
        if w > 1 {
            g.fillRoundedRect(CGRect(x: 0, y: y, width: w, height: h), radius: h / 2, color: barColor)
        }
    }
}

// MARK: - 信号总览面板

final class SignalOverviewPanel: PanelBase {

    private let priceLabel = L.label("-", size: 10, color: Theme.textDim, mono: true)
    private var rows: [SignalKind: (icon: NSImageView, level: NSTextField, score: NSTextField, bar: ScoreBarView)] = [:]
    private let summaryLabel = L.wrapped("正在分析…", size: 10.5, color: Theme.textDim)
    private let divider = NSBox()

    init() {
        super.init(title: "信号总览", icon: "waveform.path.ecg", trailing: priceLabel)

        for kind in SignalKind.allCases.sorted(by: { $0.priority < $1.priority }) {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil)
            icon.contentTintColor = Theme.color(for: kind)
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 11).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 11).isActive = true

            let name = L.label(kind.label, size: 10.5, weight: .medium, color: Theme.text)
            let level = L.label("—", size: 8.5, color: Theme.textDim)
            level.alignment = .right
            let score = L.label("—", size: 11, weight: .semibold, color: Theme.textDim, mono: true)
            score.alignment = .right
            score.widthAnchor.constraint(equalToConstant: 26).isActive = true

            let head = L.hstack([icon, name, L.spacer(), level, score], spacing: 5)
            let bar = ScoreBarView()
            bar.barColor = Theme.color(for: kind)
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.heightAnchor.constraint(equalToConstant: 3).isActive = true
            bar.setContentHuggingPriority(.required, for: .vertical)
            bar.setContentCompressionResistancePriority(.required, for: .vertical)

            let col = L.vstack([head, bar], spacing: 4)
            col.translatesAutoresizingMaskIntoConstraints = false
            col.setContentHuggingPriority(.required, for: .vertical)
            col.setContentCompressionResistancePriority(.required, for: .vertical)
            head.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            bar.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            col.heightAnchor.constraint(equalToConstant: 27).isActive = true
            addBody(col)
            rows[kind] = (icon, level, score, bar)
        }

        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        addBody(divider)
        addBody(summaryLabel)
        summaryLabel.maximumNumberOfLines = 3
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func refresh() {
        guard let a = AppState.shared.analysis else {
            summaryLabel.stringValue = "正在分析…"
            return
        }
        let ev = a.eval
        priceLabel.stringValue = Fmt.price(a.context.currentPrice)

        let values: [(SignalKind, Double)] = [
            (.buy, ev.buy.score), (.risk, ev.risk.score),
            (.accumulate, ev.accumulate.score), (.distribute, ev.distribute.score)
        ]
        for (kind, score) in values {
            guard let row = rows[kind] else { continue }
            row.score.stringValue = String(format: "%.0f", score)
            row.bar.value = score
            let active = score >= 50
            row.score.textColor = active ? Theme.color(for: kind) : Theme.textFaint
            row.level.stringValue = levelText(score)
            row.level.textColor = active ? Theme.color(for: kind).withAlphaComponent(0.85) : Theme.textFaint
        }
        summaryLabel.stringValue = a.summary
    }

    private func levelText(_ s: Double) -> String {
        if s >= 80 { return "强" }
        if s >= 65 { return "中" }
        if s >= 50 { return "弱" }
        return "—"
    }
}

// MARK: - 支撑压力面板

final class LevelsPanel: PanelBase {

    private let body = NSStackView()

    init() {
        super.init(title: "支撑 / 压力", icon: "arrow.up.and.down")
        body.orientation = .vertical
        body.spacing = 0
        body.alignment = .leading
        body.translatesAutoresizingMaskIntoConstraints = false
        addBody(body)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func refresh() {
        for v in body.arrangedSubviews {
            body.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        guard let a = AppState.shared.analysis, !a.context.levels.isEmpty else {
            let l = L.label("数据不足", size: 10, color: Theme.textDim)
            body.addArrangedSubview(l)
            l.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            return
        }

        let sorted = a.context.levels.sorted { $0.price > $1.price }
        let price = a.context.currentPrice
        var insertedSep = false

        for (i, level) in sorted.enumerated() {
            // 现价分隔
            if !insertedSep, level.kind == .support {
                insertedSep = true
                let sep = makePriceSeparator(price)
                body.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            }
            let row = makeRow(level)
            body.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            _ = i
        }
        if !insertedSep {
            let sep = makePriceSeparator(price)
            body.addArrangedSubview(sep)
            sep.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
    }

    private func makePriceSeparator(_ price: Double) -> NSView {
        let line1 = NSView()
        line1.wantsLayer = true
        line1.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.35).cgColor
        line1.translatesAutoresizingMaskIntoConstraints = false
        line1.heightAnchor.constraint(equalToConstant: 0.7).isActive = true

        let lab = L.label("现价 \(Fmt.price(price))", size: 8, weight: .medium, color: Theme.accent, mono: true)
        lab.setContentHuggingPriority(.required, for: .horizontal)

        let line2 = NSView()
        line2.wantsLayer = true
        line2.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.35).cgColor
        line2.translatesAutoresizingMaskIntoConstraints = false
        line2.heightAnchor.constraint(equalToConstant: 0.7).isActive = true

        let row = L.hstack([line1, lab, line2], spacing: 4)
        lab.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            line1.widthAnchor.constraint(greaterThanOrEqualToConstant: 4),
            line2.widthAnchor.constraint(greaterThanOrEqualToConstant: 4)
        ])
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -2),
            row.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: wrap.trailingAnchor)
        ])
        return wrap
    }

    private func makeRow(_ level: PriceLevel) -> NSView {
        let color = level.kind == .support ? Theme.buy : Theme.distribute

        let kindLab = L.label(level.kind.label, size: 8.5, weight: .medium, color: color)
        kindLab.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let priceLab = L.label(Fmt.price(level.price), size: 11, weight: .medium, color: Theme.text, mono: true)
        priceLab.widthAnchor.constraint(equalToConstant: 62).isActive = true

        // 强度点
        let dots = NSStackView()
        dots.orientation = .horizontal
        dots.spacing = 2
        dots.translatesAutoresizingMaskIntoConstraints = false
        for i in 0..<5 {
            let d = NSView()
            d.wantsLayer = true
            d.translatesAutoresizingMaskIntoConstraints = false
            let filled = Double(i) < level.score / 20
            d.layer?.backgroundColor = (filled ? color : NSColor.white.withAlphaComponent(0.09)).cgColor
            d.layer?.cornerRadius = 1
            d.widthAnchor.constraint(equalToConstant: 3).isActive = true
            d.heightAnchor.constraint(equalToConstant: 9).isActive = true
            dots.addArrangedSubview(d)
        }

        let strength = L.label(level.strengthLabel, size: 8.5, color: Theme.textDim)

        // 按来源权重从高到低排列，重要的在前
        let ordered = level.sources.sorted { $0.weight > $1.weight }
        let sources = L.label(ordered.map(\.shortLabel).joined(separator: "·"),
                              size: 8, color: Theme.textFaint)
        sources.alignment = .right
        sources.setContentHuggingPriority(.init(1), for: .horizontal)

        let dist = L.label(Fmt.pct(level.distancePct), size: 9, color: level.distancePct >= 0 ? Theme.distribute : Theme.buy, mono: true)
        dist.alignment = .right
        dist.widthAnchor.constraint(equalToConstant: 50).isActive = true

        let row = L.hstack([kindLab, priceLab, dots, strength, L.spacer(), sources, dist], spacing: 5)
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 2.5),
            row.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -2.5),
            row.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: wrap.trailingAnchor)
        ])
        return wrap
    }
}

// MARK: - 信号依据面板

final class SignalDetailPanel: PanelBase {

    private let stack = FlippedStackView()
    private var scroll: NSScrollView!

    init() {
        super.init(title: "信号依据", icon: "list.bullet.rectangle")

        stack.orientation = .vertical
        stack.spacing = 7
        stack.alignment = .leading

        let sc = makeScrollable(stack)
        scroll = sc
        addBody(sc)
        sc.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func refresh() {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        guard let a = AppState.shared.analysis,
              (!a.signals.isEmpty || !a.fearSignals.isEmpty || !a.tradePoints.isEmpty) else {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "checkmark.seal", accessibilityDescription: nil)
            icon.contentTintColor = Theme.textFaint
            let l = L.label("当前无显著信号（阈值 45 分）", size: 10, color: Theme.textDim)
            let v = L.vstack([icon, l], spacing: 5)
            v.alignment = .centerX
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return
        }

        // ---- 买卖点（新引擎日线点 + 当日分时触发，同一列表按时间倒序） ----
        addTradePointsSection(analysis: a)

        // ---- 复制分析包（仅复制到剪贴板，不联网、不自动发送） ----
        addCopyPacketRow(analysis: a)

        for sig in a.signals {
            let color = Theme.color(for: sig.kind)
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: sig.kind.symbolName, accessibilityDescription: nil)
            icon.contentTintColor = color
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 10).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 10).isActive = true

            let name = L.label(sig.kind.label, size: 10, weight: .semibold, color: color)
            let lvl = L.label(sig.level.label, size: 8, color: color.withAlphaComponent(0.85))
            let score = L.label(String(format: "%.0f", sig.score), size: 10, weight: .bold, color: color, mono: true)
            score.alignment = .right

            let head = L.hstack([icon, name, lvl, L.spacer(), score], spacing: 5)

            var reasonViews: [NSView] = [head]
            for reason in sig.reasons.prefix(5) {
                let dot = NSView()
                dot.wantsLayer = true
                dot.layer?.backgroundColor = color.withAlphaComponent(0.55).cgColor
                dot.translatesAutoresizingMaskIntoConstraints = false
                dot.layer?.cornerRadius = 1.5
                dot.widthAnchor.constraint(equalToConstant: 3).isActive = true
                dot.heightAnchor.constraint(equalToConstant: 3).isActive = true
                let text = L.wrapped(reason, size: 9.5, color: Theme.text.withAlphaComponent(0.70))
                let row = L.hstack([dot, text], spacing: 5, alignment: .top)
                row.alignment = .top
                text.widthAnchor.constraint(lessThanOrEqualToConstant: 250).isActive = true
                reasonViews.append(row)
            }

            let col = L.vstack(reasonViews, spacing: 4)
            col.translatesAutoresizingMaskIntoConstraints = false
            head.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true

            stack.addArrangedSubview(col)
            col.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // ---- 情绪信号（恐惧/贪婪日线信号，独立于四类信号） ----
        if !a.fearSignals.isEmpty {
            let sectionTitle = L.label("情绪信号 · 恐惧 / 贪婪", size: 9, weight: .semibold, color: Theme.textDim)
            stack.addArrangedSubview(sectionTitle)
            sectionTitle.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

            for fs in a.fearSignals {
                let color: NSColor = fs.sentiment == .fear ? Theme.accumulate : Theme.risk
                let name = L.label(fs.kind.label, size: 10, weight: .semibold, color: color)
                let tag = L.label(fs.sentiment.rawValue, size: 8, color: color.withAlphaComponent(0.85))
                let score = L.label(String(format: "%.0f", fs.score), size: 10, weight: .bold, color: color, mono: true)
                score.alignment = .right
                let head = L.hstack([name, tag, L.spacer(), score], spacing: 5)

                let dot = NSView()
                dot.wantsLayer = true
                dot.layer?.backgroundColor = color.withAlphaComponent(0.55).cgColor
                dot.translatesAutoresizingMaskIntoConstraints = false
                dot.layer?.cornerRadius = 1.5
                dot.widthAnchor.constraint(equalToConstant: 3).isActive = true
                dot.heightAnchor.constraint(equalToConstant: 3).isActive = true
                let text = L.wrapped(fs.reason, size: 9.5, color: Theme.text.withAlphaComponent(0.70))
                let row = L.hstack([dot, text], spacing: 5, alignment: .top)
                row.alignment = .top
                text.widthAnchor.constraint(lessThanOrEqualToConstant: 250).isActive = true

                let col = L.vstack([head, row], spacing: 4)
                col.translatesAutoresizingMaskIntoConstraints = false
                head.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
                stack.addArrangedSubview(col)
                col.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
    }

    // MARK: - 买卖点列表

    private func addTradePointsSection(analysis a: Analysis) {
        let app = AppState.shared
        // 日线点 + 当前标的的当日分时触发，合并按时间倒序
        var rows: [(date: Date, direction: TradeDirection, title: String, source: String,
                    price: Double, detail: String, reason: String, strong: Bool, vetoed: Bool)] = []
        for p in a.tradePoints {
            let rText = String(format: "%.1f", p.rMultiple)
            let detail = "止损 \(Fmt.price(p.stopLoss)) · 目标 \(Fmt.price(p.target)) · \(rText)R"
            rows.append((p.date, p.direction, p.kind.label, "日线", p.price, detail, p.reason,
                         p.isStrong, p.isVetoed))
        }
        if let currentID = app.selected?.id {
            for e in app.buyPointEntries where e.security.id == currentID {
                let t = e.trigger
                rows.append((t.time, t.direction, t.kind.label, "分时", t.price,
                             "强度 \(Fmt.price(t.strength, decimals: 0))", t.reason, false, false))
            }
        }
        guard !rows.isEmpty else { return }
        rows.sort { $0.date > $1.date }

        let title = L.label("买卖点 · 日线 + 分时", size: 9, weight: .semibold, color: Theme.textDim)
        stack.addArrangedSubview(title)
        title.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        for row in rows.prefix(8) {
            let color = row.direction == .buy ? Theme.up : Theme.down
            let dirLabel = L.label(row.direction.shortLabel, size: 10, weight: .bold, color: color)
            let name = L.label(row.title, size: 10, weight: .semibold, color: color)
            let src = L.label(row.source, size: 8, color: Theme.textFaint)
            let dateText = L.label(Fmt.date(row.date, intraday: row.source == "分时"),
                                   size: 9, color: Theme.textDim, mono: true)
            let priceText = L.label(Fmt.price(row.price), size: 10, weight: .bold, color: color, mono: true)
            priceText.alignment = .right
            var headItems: [NSView] = [dirLabel, name, src]
            if row.strong {
                headItems.append(L.label("强", size: 8, weight: .bold, color: Theme.risk))
            }
            if row.vetoed {
                headItems.append(L.label("环境否决", size: 8, color: Theme.textFaint))
            }
            headItems.append(L.spacer())
            headItems.append(dateText)
            headItems.append(priceText)
            let head = L.hstack(headItems, spacing: 5)

            let detailLine = L.wrapped(row.detail, size: 9, color: Theme.text.withAlphaComponent(0.75))
            let reasonLine = L.wrapped(row.reason, size: 9.5, color: Theme.text.withAlphaComponent(0.70))
            let col = L.vstack([head, detailLine, reasonLine], spacing: 3)
            col.translatesAutoresizingMaskIntoConstraints = false
            head.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            stack.addArrangedSubview(col)
            col.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let t1Note = L.wrapped("T+1 提示：日内止损只是提醒，隔夜跳空可能穿止损；买卖点为规则信号展示，不构成操作建议。",
                               size: 8, color: Theme.textFaint)
        stack.addArrangedSubview(t1Note)
        t1Note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // 模型解读（本地/云端任一开启时显示；云端优先，模型不可用或校验失败时回落模板文字）
        let cloudReady = app.cloudLLMConfig.isUsable && CloudLLMConfig.hasKey()
        if cloudReady || app.localLLMConfig.isUsable {
            addExplainRow(analysis: a, useCloud: cloudReady)
        }
    }

    private func addExplainRow(analysis a: Analysis, useCloud: Bool) {
        let resultLabel = L.wrapped("", size: 9.5, color: Theme.text.withAlphaComponent(0.75))
        resultLabel.isHidden = true
        let buttonTitle = useCloud ? "云端模型解读" : "本地模型解读"
        let button = NSButton()
        button.title = buttonTitle
        button.setButtonType(.momentaryChange)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: buttonTitle, attributes: [
            .font: Fonts.ui(9.5), .foregroundColor: Theme.accent
        ])
        button.wantsLayer = true
        button.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.13).cgColor
        button.layer?.cornerRadius = 3
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let statusLabel = L.label("", size: 8.5, color: Theme.textFaint)
        let row = L.hstack([button, L.spacer(), statusLabel], spacing: 6)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(resultLabel)
        resultLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // 用 target-action 承载异步调用，避免闭包持有已重建的视图
        let action = SignalExplainAction(button: button, resultLabel: resultLabel, statusLabel: statusLabel,
                                         points: a.tradePoints, useCloud: useCloud)
        button.target = action
        button.action = #selector(SignalExplainAction.run)
        // action 由按钮的 associated object 持有（见下方扩展）
        objc_setAssociatedObject(button, &explainActionKey, action, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: - 复制分析包

    private func addCopyPacketRow(analysis a: Analysis) {
        guard let input = makePacketInput(analysis: a) else { return }
        let packetText = AnalysisPacket.build(input)
        let button = NSButton()
        button.title = "复制分析包"
        button.setButtonType(.momentaryChange)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: "复制分析包", attributes: [
            .font: Fonts.ui(9.5), .foregroundColor: Theme.accent
        ])
        button.wantsLayer = true
        button.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.13).cgColor
        button.layer?.cornerRadius = 3
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let statusLabel = L.label("", size: 8.5, color: Theme.textFaint)
        let row = L.hstack([button, L.spacer(), statusLabel], spacing: 6)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let action = CopyPacketAction(button: button, statusLabel: statusLabel, packetText: packetText)
        button.target = action
        button.action = #selector(CopyPacketAction.run)
        objc_setAssociatedObject(button, &copyPacketActionKey, action, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// 组装分析包输入：全部取自已算好的数据，不编造数字。
    private func makePacketInput(analysis a: Analysis) -> AnalysisPacket.Input? {
        let app = AppState.shared
        guard let sec = app.selected else { return nil }
        var intraday: [BuyPointEntry] = []
        for e in app.buyPointEntries {
            if e.security.id == sec.id { intraday.append(e) }
        }
        return AnalysisPacket.Input(
            security: sec,
            quote: app.selectedQuote,
            lastClose: a.context.closes.last,
            generatedAt: Date(),
            summary: a.summary,
            emotion: app.emotionSnapshot,
            tradePoints: a.tradePoints,
            fearSignals: a.fearSignals,
            supports: a.supports,
            resistances: a.resistances,
            intraday: intraday
        )
    }
}

// MARK: - 模型解读动作（避免闭包持有重建视图）

private var explainActionKey: UInt8 = 0

private final class SignalExplainAction: NSObject {
    private weak var button: NSButton?
    private weak var resultLabel: NSTextField?
    private weak var statusLabel: NSTextField?
    private let points: [TradePointSignal]
    private let useCloud: Bool

    init(button: NSButton, resultLabel: NSTextField, statusLabel: NSTextField,
         points: [TradePointSignal], useCloud: Bool) {
        self.button = button
        self.resultLabel = resultLabel
        self.statusLabel = statusLabel
        self.points = points
        self.useCloud = useCloud
    }

    @objc func run() {
        guard let button, let resultLabel, let statusLabel else { return }
        button.isEnabled = false
        let sourceName = useCloud ? "云端模型" : "本地模型"
        statusLabel.stringValue = "\(sourceName)解读中…"
        statusLabel.textColor = Theme.textDim
        let app = AppState.shared
        let breadth = app.emotionSnapshot?.breadth
        let points = self.points
        let useCloud = self.useCloud
        Task { @MainActor in
            var text = ""
            var fromLLM = false
            if useCloud {
                let cfg = app.cloudLLMConfig
                let key = CloudLLMConfig.loadKey() ?? ""
                let result = await CloudLLMClient.shared.explain(
                    points: points, breadth: breadth, config: cfg, apiKey: key
                )
                text = result.text
                fromLLM = result.fromLLM
            } else {
                let cfg = app.localLLMConfig
                let result = await LocalLLMClient.shared.explain(
                    points: points, breadth: breadth, config: cfg
                )
                text = result.text
                fromLLM = result.fromLLM
            }
            // 面板可能已重建：视图脱离层级时不再更新
            guard resultLabel.superview != nil else { return }
            resultLabel.isHidden = false
            resultLabel.stringValue = text
            statusLabel.stringValue = fromLLM ? "\(sourceName)解读（已校验数字）" : "模板解读（\(sourceName)不可用或校验未通过）"
            statusLabel.textColor = Theme.textFaint
            button.isEnabled = true
        }
    }
}

// MARK: - 复制分析包动作

private var copyPacketActionKey: UInt8 = 0

/// 只复制到系统剪贴板，不联网、不自动发送。用户自己粘贴到聊天里发给 Kit。
private final class CopyPacketAction: NSObject {
    private weak var button: NSButton?
    private weak var statusLabel: NSTextField?
    private let packetText: String

    init(button: NSButton, statusLabel: NSTextField, packetText: String) {
        self.button = button
        self.statusLabel = statusLabel
        self.packetText = packetText
    }

    @objc func run() {
        guard let statusLabel else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(packetText, forType: .string)
        statusLabel.stringValue = "已复制分析包，去聊天里粘贴发给 Kit"
        statusLabel.textColor = Theme.buy
    }
}

// MARK: - 回测面板

final class BacktestPanel: PanelBase {

    private let body = NSStackView()
    private let horizons = [1, 5, 10]

    init() {
        super.init(title: "信号历史胜率", icon: "chart.bar.xaxis")
        body.orientation = .vertical
        body.spacing = 1
        body.alignment = .leading
        body.translatesAutoresizingMaskIntoConstraints = false
        addBody(body)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    private func cell(_ text: String, width: CGFloat, color: NSColor = Theme.textDim,
                      size: CGFloat = 9, weight: NSFont.Weight = .regular, align: NSTextAlignment = .right,
                      mono: Bool = true) -> NSTextField {
        let l = L.label(text, size: size, weight: weight, color: color, mono: mono)
        l.alignment = align
        l.widthAnchor.constraint(equalToConstant: width).isActive = true
        return l
    }

    func refresh() {
        for v in body.arrangedSubviews {
            body.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let results = AppState.shared.backtest
        guard !results.isEmpty, results.contains(where: { $0.samples > 0 }) else {
            let l = L.label("样本不足，暂无法回测", size: 10, color: Theme.textDim)
            body.addArrangedSubview(l)
            l.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            return
        }

        // 表头
        var header: [NSView] = [
            cell("类型", width: 52, align: .left, mono: false),
            cell("样本", width: 32),
            cell("胜率", width: 40)
        ]
        for h in horizons {
            header.append(cell("\(h)日", width: 44))
        }
        let headerRow = L.hstack(header, spacing: 2)
        body.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        for r in results where r.samples > 0 {
            var cells: [NSView] = [
                cell(r.kind.label, width: 52, color: Theme.color(for: r.kind), size: 9.5,
                     weight: .medium, align: .left, mono: false),
                cell("\(r.samples)", width: 32),
                cell(Fmt.pct(r.winRate * 100, decimals: 0, sign: false), width: 40,
                     color: r.winRate >= 0.55 ? Theme.buy : (r.winRate >= 0.45 ? Theme.risk : Theme.distribute),
                     weight: .semibold)
            ]
            for h in horizons {
                if let v = r.avgReturn[h] {
                    cells.append(cell(Fmt.pct(v, decimals: 1), width: 44, color: Theme.color(change: v)))
                } else {
                    cells.append(cell("—", width: 44, color: Theme.textFaint))
                }
            }
            let row = L.hstack(cells, spacing: 2)
            body.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        let note = L.wrapped("胜率按信号后5日方向计：买入/进场以涨为胜，风险/撤退以跌为胜",
                             size: 8, color: Theme.textFaint)
        note.preferredMaxLayoutWidth = 260
        body.addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }
}

// MARK: - 资金流面板

final class FundFlowPanel: PanelBase {

    private let body = NSStackView()

    init() {
        super.init(title: "主力资金", icon: "banknote")
        body.orientation = .vertical
        body.spacing = 6
        body.alignment = .leading
        body.translatesAutoresizingMaskIntoConstraints = false
        addBody(body)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func refresh() {
        for v in body.arrangedSubviews {
            body.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        guard let d = AppState.shared.data else { return }
        guard let f = d.fundFlow else {
            let l = L.label("该市场暂无资金流数据", size: 10, color: Theme.textDim)
            body.addArrangedSubview(l)
            l.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            return
        }

        let title = L.label("主力净额", size: 8.5, color: Theme.textDim)
        let value = L.label(Fmt.money(f.mainNet), size: 17, weight: .medium,
                            color: Theme.color(change: f.mainNet), mono: true)
        let left = L.vstack([title, value], spacing: 1)

        var rightViews: [NSView] = []
        for (label, v) in [("超大单", f.superLargeNet), ("大单", f.largeNet),
                           ("中单", f.mediumNet), ("小单", f.smallNet)] {
            let l = L.label(label, size: 8, color: Theme.textDim)
            l.widthAnchor.constraint(equalToConstant: 34).isActive = true
            let val = L.label(Fmt.money(v), size: 9, color: Theme.color(change: v), mono: true)
            val.alignment = .right
            val.widthAnchor.constraint(equalToConstant: 62).isActive = true
            let row = L.hstack([l, val], spacing: 4)
            rightViews.append(row)
        }
        let right = L.vstack(rightViews, spacing: 2)

        let top = L.hstack([left, L.spacer(), right], spacing: 8, alignment: .top)
        top.alignment = .top
        body.addArrangedSubview(top)
        top.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        // 近10日柱状
        let hist = Array(d.fundFlowHistory.suffix(10))
        if hist.count >= 2 {
            let chart = FundFlowBars(history: hist)
            chart.translatesAutoresizingMaskIntoConstraints = false
            body.addArrangedSubview(chart)
            chart.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            chart.heightAnchor.constraint(equalToConstant: 38).isActive = true
        }
    }
}

/// 近N日主力净额柱状图
final class FundFlowBars: NSView {
    private let history: [FundFlow]

    init(history: [FundFlow]) {
        self.history = history
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext, !history.isEmpty else { return }
        let maxAbs = max(history.map { abs($0.mainNet) }.max() ?? 1, 1)
        let midY = bounds.height / 2
        let n = history.count
        let slot = bounds.width / CGFloat(max(n, 1))
        let bw = min(slot * 0.62, 14)

        // 零轴
        g.strokeLine(from: CGPoint(x: 0, y: midY), to: CGPoint(x: bounds.width, y: midY),
                     color: Theme.border.alpha(0.7), width: 0.5)

        for (i, f) in history.enumerated() {
            let x = slot * CGFloat(i) + slot / 2
            let ratio = CGFloat(abs(f.mainNet) / maxAbs)
            let h = max(1.2, ratio * (bounds.height / 2 - 6))
            let color = (f.mainNet >= 0 ? Theme.up : Theme.down).withAlphaComponent(0.78)
            let rect: CGRect
            if f.mainNet >= 0 {
                rect = CGRect(x: x - bw / 2, y: midY - h, width: bw, height: h)
            } else {
                rect = CGRect(x: x - bw / 2, y: midY, width: bw, height: h)
            }
            g.fillRoundedRect(rect, radius: 1.2, color: color)

            // 日期（每隔一个标一次）
            if n <= 10 || i % 2 == 0, let d = f.date {
                let s = String(Fmt.shortDateFormatter.string(from: d).suffix(2))
                g.drawText(s, at: CGPoint(x: x, y: bounds.height - 10),
                           font: Fonts.mono(6.5), color: Theme.textFaint, align: .center)
            }
        }
    }
}

// MARK: - 趋势面板

final class TrendPanel: PanelBase {

    private let body = NSStackView()

    init() {
        super.init(title: "趋势结构", icon: "chart.line.uptrend.xyaxis")
        body.orientation = .vertical
        body.spacing = 5
        body.alignment = .leading
        body.translatesAutoresizingMaskIntoConstraints = false
        addBody(body)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func refresh() {
        for v in body.arrangedSubviews {
            body.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        guard let trend = AppState.shared.analysis?.context.trend else {
            let l = L.label("数据不足（需≥60根K线）", size: 10, color: Theme.textDim)
            body.addArrangedSubview(l)
            l.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            return
        }

        let color = trend.direction.isBullish ? Theme.up : (trend.direction == .sideways ? Theme.risk : Theme.down)
        let name = L.label(trend.direction.label, size: 11, weight: .semibold, color: color)
        name.setContentHuggingPriority(.required, for: .horizontal)
        let bar = ScoreBarView()
        bar.value = trend.strength
        bar.barColor = color
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 3).isActive = true
        bar.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let num = L.label(String(format: "%.0f", trend.strength), size: 9.5, weight: .bold,
                          color: Theme.textDim, mono: true)
        num.setContentHuggingPriority(.required, for: .horizontal)

        let head = L.hstack([name, bar, num, L.spacer()], spacing: 6)
        body.addArrangedSubview(head)
        head.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        let desc = L.wrapped(trend.description, size: 8.5, color: Theme.text.withAlphaComponent(0.58))
        desc.preferredMaxLayoutWidth = 265
        desc.maximumNumberOfLines = 2
        body.addArrangedSubview(desc)
        desc.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true

        // 2×2 网格，节省纵向空间
        func pair(_ l1: String, _ v1: String, _ c1: NSColor,
                  _ l2: String, _ v2: String, _ c2: NSColor) -> NSView {
            let a = L.label(l1, size: 8, color: Theme.textDim)
            let av = L.label(v1, size: 8.5, color: c1, mono: true)
            av.alignment = .right
            let b = L.label(l2, size: 8, color: Theme.textDim)
            let bv = L.label(v2, size: 8.5, color: c2, mono: true)
            bv.alignment = .right
            av.widthAnchor.constraint(equalToConstant: 52).isActive = true
            bv.widthAnchor.constraint(equalToConstant: 52).isActive = true
            let left = L.hstack([a, av], spacing: 3)
            let right = L.hstack([b, bv], spacing: 3)
            return L.hstack([left, L.spacer(), right], spacing: 8)
        }
        let r1 = pair("MA20斜率", Fmt.pct(trend.ma20Slope, decimals: 2, sign: false), Theme.color(change: trend.ma20Slope),
                      "MA60斜率", Fmt.pct(trend.ma60Slope, decimals: 2, sign: false), Theme.color(change: trend.ma60Slope))
        let r2 = pair("偏离MA20", Fmt.pct(trend.priceVsMA20), Theme.color(change: trend.priceVsMA20),
                      "偏离MA60", Fmt.pct(trend.priceVsMA60), Theme.color(change: trend.priceVsMA60))
        for r in [r1, r2] {
            body.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
    }
}
