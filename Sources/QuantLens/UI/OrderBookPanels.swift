import AppKit

// MARK: - 五档盘口面板

/// 同花顺风格的盘口：卖5→卖1 从上往下，买1→买5 接着往下。
/// 每档显示 价格 / 挂单量，并用横向背景条表示挂单量的相对大小。
final class OrderBookPanel: PanelBase {

    private let body = FlippedStackView()
    private var rows: [OrderBookRow] = []
    /// 买卖盘之间的分隔横杠
    private let divider = OrderBookDivider()
    private let ratioLabel = L.label("", size: 8.5, color: Theme.textFaint, mono: true)
    private let outerLabel = L.label("", size: 8.5, color: Theme.textFaint, mono: true)

    init() {
        super.init(title: "五档盘口", icon: "list.number")
        body.orientation = .vertical
        body.spacing = 0
        body.alignment = .leading
        body.translatesAutoresizingMaskIntoConstraints = false

        // 5 卖 → 分隔横杠 → 5 买
        for i in 0..<5 {
            let row = OrderBookRow()
            row.translatesAutoresizingMaskIntoConstraints = false
            body.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 15).isActive = true
            rows.append(row)
        }

        // 买卖之间的分隔横杠（便于一眼区分卖盘与买盘）
        body.addArrangedSubview(divider)
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 13).isActive = true

        for _ in 0..<5 {
            let row = OrderBookRow()
            row.translatesAutoresizingMaskIntoConstraints = false
            body.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 15).isActive = true
            rows.append(row)
        }

        addBody(body)

        let footRow = L.hstack([ratioLabel, L.spacer(), outerLabel], spacing: 6)
        addBody(footRow)
        footRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func refresh(book: OrderBook?, previousClose: Double) {
        guard let book else {
            for r in rows { r.update(level: nil, isAsk: false, maxVolume: 1) }
            ratioLabel.stringValue = ""
            outerLabel.stringValue = ""
            return
        }

        let maxVol = max(book.bids.map(\.volume).max() ?? 1, book.asks.map(\.volume).max() ?? 1)
        let priceColor: (Double) -> NSColor = { p in
            guard previousClose > 0 else { return Theme.text }
            return Theme.color(change: p - previousClose)
        }

        // 卖5 → 卖1（倒序）
        for i in 0..<5 {
            let idx = 4 - i
            guard idx < book.asks.count else { continue }
            rows[i].update(level: book.asks[idx], isAsk: true, maxVolume: maxVol,
                           color: priceColor(book.asks[idx].price))
        }
        // 买1 → 买5
        for i in 0..<5 {
            guard i < book.bids.count else { continue }
            let rowIdx = 5 + i
            rows[rowIdx].update(level: book.bids[i], isAsk: false, maxVolume: maxVol,
                                color: priceColor(book.bids[i].price))
        }

        ratioLabel.stringValue = String(format: "委比 %+.1f%%  差 %.0f手",
                                        book.bidAskRatio, book.bidAskDiff)
        ratioLabel.textColor = book.bidAskRatio >= 0 ? Theme.up : Theme.down
        outerLabel.stringValue = String(format: "外%.0f 内%.0f", book.outerVolume, book.innerVolume)
    }
}

/// 一档盘口行
/// 买卖盘之间的分隔横杠。中间画一条带渐变的细线，
/// 两侧配短竖标记，视觉上把「卖盘区」和「买盘区」切开。
final class OrderBookDivider: NSView {

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        let midY = bounds.midY
        let inset: CGFloat = 2

        // 主横线：加粗到 2pt，横贯全宽
        let lineH: CGFloat = 2
        g.setFillColor(Theme.border.alpha(0.95).cgColor)
        g.fill(CGRect(x: inset, y: midY - lineH / 2, width: bounds.width - inset * 2, height: lineH))

        // 中央加粗段：4pt，更醒目地分隔买卖盘
        let centerW = min(90, bounds.width * 0.34)
        g.setFillColor(Theme.textFaint.alpha(0.95).cgColor)
        g.fill(CGRect(x: bounds.midX - centerW / 2, y: midY - 2,
                      width: centerW, height: 4))

        // 左右端短竖标记：加高到 7pt，视觉上勾住分界线
        let tickH: CGFloat = 7
        let tickW: CGFloat = 1.5
        g.setFillColor(Theme.textFaint.alpha(0.85).cgColor)
        g.fill(CGRect(x: inset, y: midY - tickH / 2, width: tickW, height: tickH))
        g.fill(CGRect(x: bounds.width - inset - tickW, y: midY - tickH / 2, width: tickW, height: tickH))
    }
}

final class OrderBookRow: NSView {
    private let tagLabel = L.label("", size: 8.5, color: Theme.textFaint)
    private let priceLabel = L.label("", size: 9.5, weight: .medium, mono: true)
    private let volLabel = L.label("", size: 8.5, color: Theme.textDim, mono: true)
    private var barRatio: Double = 0
    private var barColor: NSColor = Theme.textFaint
    private var isAskRow = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // 三列固定宽度，整体贴左排列。
        // 关键：标签列必须锁死宽度 + 高抗压缩，否则会被价格/量列挤成 0 宽而完全不显示。
        tagLabel.widthAnchor.constraint(equalToConstant: 30).isActive = true
        tagLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        tagLabel.setContentHuggingPriority(.required, for: .horizontal)

        priceLabel.alignment = .left
        priceLabel.widthAnchor.constraint(equalToConstant: 66).isActive = true
        priceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        volLabel.alignment = .right
        volLabel.widthAnchor.constraint(equalToConstant: 62).isActive = true
        volLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = L.hstack([tagLabel, priceLabel, volLabel], spacing: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            // 贴左 4pt，右侧不强制贴边 —— 内容左移，避免被推到面板右侧
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
        ])
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext, barRatio > 0 else { return }
        // 从右往左的挂单量背景条
        let w = bounds.width * CGFloat(min(barRatio, 1)) * 0.92
        g.fillRect(CGRect(x: bounds.width - w, y: 1, width: w, height: bounds.height - 2),
                   barColor.alpha(0.13))
    }

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    func update(level: OrderBookLevel?, isAsk: Bool, maxVolume: Double, color: NSColor? = nil) {
        isAskRow = isAsk
        guard let level, level.price > 0 else {
            tagLabel.stringValue = ""
            priceLabel.stringValue = ""
            volLabel.stringValue = ""
            barRatio = 0
            needsDisplay = true
            return
        }
        tagLabel.stringValue = (isAsk ? "卖" : "买") + "\(level.level)"
        tagLabel.textColor = isAsk ? Theme.down.alpha(0.85) : Theme.up.alpha(0.85)
        priceLabel.stringValue = Fmt.price(level.price, decimals: level.price >= 100 ? 2 : 3)
        priceLabel.textColor = color ?? Theme.text
        // 委托量：整数手，千手以上用逗号分隔便于阅读
        let v = Int(level.volume)
        volLabel.stringValue = v >= 10000
            ? String(format: "%.1f万", level.volume / 10000)
            : (v >= 1000 ? Self.grouped(v) : "\(v)")
        volLabel.textColor = isAsk ? Theme.down.alpha(0.9) : Theme.up.alpha(0.9)
        barRatio = maxVolume > 0 ? level.volume / maxVolume : 0
        barColor = (color ?? Theme.textFaint)
        needsDisplay = true
    }
}

// MARK: - 成交明细面板

/// 实时逐笔。大单高亮（≥500手 或 ≥100万），特大单加重。
final class TradeTapePanel: PanelBase {

    private let body = FlippedStackView()
    private var tradeRows: [TradeRowView] = []
    private let statsLabel = L.label("", size: 8, color: Theme.textFaint, mono: true)
    private let thresholdButton = NSButton()
    private var threshold: LargeThreshold = .medium

    /// 显示行数
    private let maxRows = 14

    init() {
        super.init(title: "成交明细", icon: "text.append")

        thresholdButton.setButtonType(.momentaryChange)
        thresholdButton.isBordered = false
        thresholdButton.wantsLayer = true
        thresholdButton.layer?.cornerRadius = 3
        thresholdButton.target = self
        thresholdButton.action = #selector(cycleThreshold)
        thresholdButton.translatesAutoresizingMaskIntoConstraints = false
        thresholdButton.heightAnchor.constraint(equalToConstant: 15).isActive = true
        updateThresholdChip()

        body.orientation = .vertical
        body.spacing = 0
        body.alignment = .leading
        body.translatesAutoresizingMaskIntoConstraints = false

        // 表头
        let header = makeHeader()
        body.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        header.heightAnchor.constraint(equalToConstant: 13).isActive = true

        for _ in 0..<maxRows {
            let r = TradeRowView()
            r.translatesAutoresizingMaskIntoConstraints = false
            body.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            r.heightAnchor.constraint(equalToConstant: 13).isActive = true
            tradeRows.append(r)
        }

        let scroll = makeScrollable(body)
        addBody(scroll)
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true

        addBody(statsLabel)
        statsLabel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        addHeaderAccessory(thresholdButton)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    private func makeHeader() -> NSView {
        let t = L.label("时间", size: 7.5, color: Theme.textFaint, mono: true)
        t.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let p = L.label("价格", size: 7.5, color: Theme.textFaint, mono: true)
        p.alignment = .right
        p.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let v = L.label("量", size: 7.5, color: Theme.textFaint, mono: true)
        v.alignment = .right
        v.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let a = L.label("金额", size: 7.5, color: Theme.textFaint, mono: true)
        a.alignment = .right
        a.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let s = L.label("向", size: 7.5, color: Theme.textFaint, mono: true)
        s.alignment = .center
        s.widthAnchor.constraint(equalToConstant: 14).isActive = true
        return L.hstack([t, p, v, a, s], spacing: 3)
    }

    @objc private func cycleThreshold() {
        let all = LargeThreshold.allCases
        if let i = all.firstIndex(of: threshold) {
            threshold = all[(i + 1) % all.count]
        }
        updateThresholdChip()
        if let last = AppState.shared.trades.last {
            _ = last
        }
        refresh(trades: AppState.shared.trades)
    }

    private func updateThresholdChip() {
        thresholdButton.attributedTitle = NSAttributedString(string: "大单≥\(threshold.rawValue)", attributes: [
            .font: Fonts.ui(7.5, weight: .medium),
            .foregroundColor: Theme.risk
        ])
        thresholdButton.layer?.backgroundColor = Theme.risk.withAlphaComponent(0.15).cgColor
    }

    func refresh(trades: [Trade]) {
        // 最新在最上面
        let recent = Array(trades.suffix(maxRows).reversed())
        let prevClose = AppState.shared.intraday?.previousClose ?? 0

        for (i, row) in tradeRows.enumerated() {
            if i < recent.count {
                row.update(trade: recent[i], previousClose: prevClose, threshold: threshold)
                row.isHidden = false
            } else {
                row.isHidden = true
            }
        }

        // 大单统计
        let stats = LargeOrderStats.summarize(trades, threshold: threshold)
        if stats.totalAmount > 0 {
            let net = stats.netAmount
            statsLabel.stringValue = String(
                format: "大单 买%d笔 %@ / 卖%d笔 %@　净 %@",
                stats.buyCount, Fmt.money(stats.buyAmount),
                stats.sellCount, Fmt.money(stats.sellAmount),
                Fmt.money(net)
            )
            statsLabel.textColor = net >= 0 ? Theme.up : Theme.down
        } else {
            statsLabel.stringValue = "今日暂无量能达标的单笔"
            statsLabel.textColor = Theme.textFaint
        }
    }
}

/// 一笔成交行
final class TradeRowView: NSView {
    private let timeLabel = L.label("", size: 8, color: Theme.textFaint, mono: true)
    private let priceLabel = L.label("", size: 8.5, mono: true)
    private let volLabel = L.label("", size: 8, color: Theme.textDim, mono: true)
    private let amountLabel = L.label("", size: 8, color: Theme.textDim, mono: true)
    private let sideLabel = L.label("", size: 8, weight: .semibold, mono: true)
    private var highlight: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        timeLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        priceLabel.alignment = .right
        priceLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        volLabel.alignment = .right
        volLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        amountLabel.alignment = .right
        amountLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        sideLabel.alignment = .center
        sideLabel.widthAnchor.constraint(equalToConstant: 14).isActive = true

        let row = L.hstack([timeLabel, priceLabel, volLabel, amountLabel, sideLabel], spacing: 3)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1)
        ])
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func draw(_ dirtyRect: NSRect) {
        guard let hl = highlight, let g = NSGraphicsContext.current?.cgContext else { return }
        g.fillRect(bounds, hl.alpha(0.14))
    }

    func update(trade: Trade, previousClose: Double, threshold: LargeThreshold) {
        timeLabel.stringValue = Fmt.intradayFormatter.string(from: trade.time)
        priceLabel.stringValue = Fmt.price(trade.price, decimals: trade.price >= 100 ? 2 : 3)

        let chgColor: NSColor
        // 按买卖方向着色：主动买（外盘）红、主动卖（内盘）绿。
        // 一眼区分谁在扫货、谁在砸盘，比按昨收涨跌着色更有交易意义。
        switch trade.side {
        case .buy:
            chgColor = Theme.up
        case .sell:
            chgColor = Theme.down
        case .neutral:
            chgColor = Theme.textDim
        }
        priceLabel.textColor = chgColor

        volLabel.stringValue = "\(Int(trade.volume))"
        amountLabel.stringValue = trade.amount >= 10_000
            ? String(format: "%.1f万", trade.amountInWan)
            : String(format: "%.0f", trade.amount)

        // 量、额跟随买卖方向着色，整行颜色统一，扫一眼就能分出买卖
        volLabel.textColor = chgColor
        amountLabel.textColor = chgColor.alpha(0.85)

        sideLabel.stringValue = trade.side.label
        switch trade.side {
        case .buy: sideLabel.textColor = Theme.up
        case .sell: sideLabel.textColor = Theme.down
        case .neutral: sideLabel.textColor = Theme.textFaint
        }

        // 大单高亮
        let isBig = threshold.matches(trade)
        highlight = isBig ? (trade.side == .sell ? Theme.down : Theme.up) : nil
        priceLabel.font = isBig ? Fonts.mono(8.5, weight: .bold) : Fonts.mono(8.5)
        volLabel.font = isBig ? Fonts.mono(8, weight: .semibold) : Fonts.mono(8)
        needsDisplay = true
    }
}

// MARK: - 大单监控面板

/// 全自选股的大单扫描结果，按净流入排序。
final class LargeOrderMonitorPanel: PanelBase {

    private let body = FlippedStackView()
    private var rows: [LargeOrderSummaryRow] = []
    private let statusLabel = L.label("", size: 8.5, color: Theme.textFaint)
    private let refreshButton = NSButton()

    private let maxRows = 10

    init() {
        super.init(title: "大单监控", icon: "flame")

        refreshButton.setButtonType(.momentaryChange)
        refreshButton.isBordered = false
        refreshButton.wantsLayer = true
        refreshButton.layer?.cornerRadius = 3
        refreshButton.attributedTitle = NSAttributedString(string: "扫描", attributes: [
            .font: Fonts.ui(8, weight: .medium), .foregroundColor: Theme.risk
        ])
        refreshButton.layer?.backgroundColor = Theme.risk.withAlphaComponent(0.16).cgColor
        refreshButton.target = self
        refreshButton.action = #selector(doScan)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.heightAnchor.constraint(equalToConstant: 15).isActive = true
        refreshButton.widthAnchor.constraint(equalToConstant: 30).isActive = true

        body.orientation = .vertical
        body.spacing = 1
        body.alignment = .leading
        body.translatesAutoresizingMaskIntoConstraints = false

        for _ in 0..<maxRows {
            let r = LargeOrderSummaryRow()
            r.translatesAutoresizingMaskIntoConstraints = false
            body.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            r.heightAnchor.constraint(equalToConstant: 26).isActive = true
            rows.append(r)
        }

        let scroll = makeScrollable(body)
        addBody(scroll)
        scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true

        addBody(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        addHeaderAccessory(refreshButton)
        observe()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func observe() {
        NotificationCenter.default.addObserver(self, selector: #selector(onScan),
                                              name: AppState.didChangeLargeOrderScan, object: nil)
    }

    @objc private func onScan() { refresh() }

    @objc private func doScan() {
        AppState.shared.scanLargeOrders()
    }

    func refresh() {
        let app = AppState.shared
        let results = app.largeOrderScans

        if app.isScanningLargeOrders {
            statusLabel.stringValue = "扫描中 \(app.largeOrderProgress.done)/\(app.largeOrderProgress.total)…"
            statusLabel.textColor = Theme.accent
            return
        }

        guard !results.isEmpty else {
            for r in rows { r.isHidden = true }
            statusLabel.stringValue = "点击「扫描」检查全部自选的大单动向"
            statusLabel.textColor = Theme.textFaint
            return
        }

        for (i, row) in rows.enumerated() {
            if i < results.count {
                row.update(results[i])
                row.isHidden = false
            } else {
                row.isHidden = true
            }
        }
        statusLabel.stringValue = "\(results.count) 只 · \(Fmt.intradayFormatter.string(from: Date()))"
        statusLabel.textColor = Theme.textFaint
    }
}

/// 大单汇总行
final class LargeOrderSummaryRow: NSView {
    private let nameLabel = L.label("", size: 9.5, weight: .medium)
    private let codeLabel = L.label("", size: 7.5, color: Theme.textFaint, mono: true)
    private let netLabel = L.label("", size: 10, weight: .semibold, mono: true)
    private let detailLabel = L.label("", size: 7.5, color: Theme.textDim, mono: true)
    private let barView = ScoreBarView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        nameLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        netLabel.alignment = .right
        netLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true

        barView.translatesAutoresizingMaskIntoConstraints = false
        barView.heightAnchor.constraint(equalToConstant: 2.5).isActive = true

        let top = L.hstack([nameLabel, codeLabel, L.spacer(), netLabel], spacing: 4)
        let col = L.vstack([top, detailLabel, barView], spacing: 1)
        addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            col.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3)
        ])
        for v in [top, detailLabel, barView] {
            v.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func update(_ r: LargeOrderScanResult) {
        nameLabel.stringValue = r.security.name.isEmpty ? r.security.displayCode : r.security.name
        codeLabel.stringValue = r.security.displayCode
        netLabel.stringValue = Fmt.money(r.netAmount)
        netLabel.textColor = r.netAmount >= 0 ? Theme.up : Theme.down
        detailLabel.stringValue = String(
            format: "买%d笔 %@ / 卖%d笔 %@",
            r.buyCount, Fmt.money(r.buyAmount), r.sellCount, Fmt.money(r.sellAmount)
        )
        barView.value = r.buyRatio
        barView.barColor = r.netAmount >= 0 ? Theme.up : Theme.down
    }
}
