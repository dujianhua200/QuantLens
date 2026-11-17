import AppKit

// MARK: - 自选列表行

final class WatchRowView: NSView {

    let item: WatchItem
    private let onSelect: (String) -> Void
    private let onRemove: (String) -> Void

    private let nameLabel = L.label("", size: 11, weight: .medium)
    private let codeLabel = L.label("", size: 8.5, color: Theme.textFaint, mono: true)
    private let priceLabel = L.label("—", size: 11, weight: .medium, mono: true)
    private let pctLabel = L.label("—", size: 9, mono: true)
    private let signalDot = NSView()

    private var isSelected = false
    private var isHovered = false

    init(item: WatchItem, onSelect: @escaping (String) -> Void, onRemove: @escaping (String) -> Void) {
        self.item = item
        self.onSelect = onSelect
        self.onRemove = onRemove
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5

        nameLabel.stringValue = item.security.name.isEmpty ? item.security.displayCode : item.security.name
        codeLabel.stringValue = item.security.displayCode

        signalDot.wantsLayer = true
        signalDot.layer?.cornerRadius = 2.5
        signalDot.translatesAutoresizingMaskIntoConstraints = false
        signalDot.widthAnchor.constraint(equalToConstant: 5).isActive = true
        signalDot.heightAnchor.constraint(equalToConstant: 5).isActive = true
        signalDot.layer?.backgroundColor = NSColor.clear.cgColor

        let nameRow = L.hstack([signalDot, nameLabel], spacing: 4)
        let left = L.vstack([nameRow, codeLabel], spacing: 0)
        left.alignment = .leading
        nameRow.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true

        priceLabel.alignment = .right
        pctLabel.alignment = .right
        priceLabel.widthAnchor.constraint(equalToConstant: 58).isActive = true
        pctLabel.widthAnchor.constraint(equalToConstant: 58).isActive = true
        let right = L.vstack([priceLabel, pctLabel], spacing: 0)
        right.alignment = .trailing

        let row = L.hstack([left, L.spacer(), right], spacing: 4)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)

        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)

        let menu = NSMenu()
        let removeItem = NSMenuItem(title: "从自选移除", action: #selector(handleRemove), keyEquivalent: "")
        removeItem.target = self
        menu.addItem(removeItem)

        let topItem = NSMenuItem(title: "置顶", action: #selector(handleMoveTop), keyEquivalent: "")
        topItem.target = self
        menu.addItem(topItem)

        menu.addItem(.separator())

        let copyCode = NSMenuItem(title: "复制代码", action: #selector(handleCopyCode), keyEquivalent: "")
        copyCode.target = self
        menu.addItem(copyCode)

        let scanOne = NSMenuItem(title: "单独扫描", action: #selector(handleScanOne), keyEquivalent: "")
        scanOne.target = self
        menu.addItem(scanOne)

        self.menu = menu
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    @objc private func handleClick() { onSelect(item.id) }
    @objc private func handleRemove() { onRemove(item.id) }

    @objc private func handleMoveTop() {
        AppState.shared.moveToTop(item.id)
    }

    @objc private func handleCopyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.security.displayCode, forType: .string)
    }

    @objc private func handleScanOne() {
        AppState.shared.scanSingle(item.security)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; updateBg(animated: false) }
    override func mouseExited(with event: NSEvent) { isHovered = false; updateBg(animated: false) }

    func setSelected(_ selected: Bool, animated: Bool = true) {
        isSelected = selected
        updateBg(animated: animated)
    }

    private func updateBg(animated: Bool) {
        let color: NSColor
        if isSelected {
            color = Theme.accent.withAlphaComponent(0.18)
        } else if isHovered {
            color = NSColor.white.withAlphaComponent(0.04)
        } else {
            color = .clear
        }
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            layer?.backgroundColor = color.cgColor
            CATransaction.commit()
        } else {
            layer?.backgroundColor = color.cgColor
        }
    }

    func update(quote: Quote?) {
        guard let q = quote else {
            priceLabel.stringValue = "—"
            pctLabel.stringValue = "—"
            priceLabel.textColor = Theme.textDim
            pctLabel.textColor = Theme.textFaint
            return
        }
        let decimals = q.price >= 10 ? 2 : 3
        priceLabel.stringValue = Fmt.price(q.price, decimals: decimals)
        pctLabel.stringValue = Fmt.pct(q.changePct)
        let color = Theme.color(change: q.changePct)
        priceLabel.textColor = color
        pctLabel.textColor = color
    }

    /// 用扫描结果点亮信号点
    func setSignal(kind: SignalKind?, score: Double) {
        guard let kind, score >= 60 else {
            signalDot.layer?.backgroundColor = NSColor.clear.cgColor
            return
        }
        signalDot.layer?.backgroundColor = Theme.color(for: kind).cgColor
    }
}

// MARK: - 搜索结果行

/// 不拦截鼠标事件的 NSStackView：让父视图能收到 mouseDown
final class PassthroughStackView: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // 只有按钮接收事件；label 等纯展示视图全部透传给父视图
        let hit = super.hitTest(point)
        if let hit, hit is NSButton { return hit }
        return nil
    }
}

final class SearchHitRow: NSView {
    private let hit: SearchHit
    private let onPreview: (Security) -> Void
    private let onAdd: (Security) -> Void
    private var hovered = false
    private let addButton = NSButton()
    private var inWatchlist: Bool

    init(hit: SearchHit, alreadyAdded: Bool, onPreview: @escaping (Security) -> Void,
         onAdd: @escaping (Security) -> Void) {
        self.hit = hit
        self.onPreview = onPreview
        self.onAdd = onAdd
        self.inWatchlist = alreadyAdded
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 3

        let name = L.label(hit.security.name.isEmpty ? hit.security.displayCode : hit.security.name,
                           size: 10.5, weight: .medium)
        let code = L.label(hit.security.displayCode, size: 8.5, color: Theme.textFaint, mono: true)

        let kindBadge = L.label(hit.kindLabel, size: 7.5, color: Theme.accent.withAlphaComponent(0.9))
        kindBadge.setContentHuggingPriority(.required, for: .horizontal)

        addButton.title = alreadyAdded ? "✓" : "+"
        addButton.setButtonType(.momentaryChange)
        addButton.isBordered = false
        addButton.font = Fonts.ui(12, weight: .semibold)
        addButton.contentTintColor = alreadyAdded ? Theme.textFaint : Theme.buy
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.widthAnchor.constraint(equalToConstant: 16).isActive = true
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.isEnabled = !alreadyAdded
        // 不用 tooltip：+/✓ 图标本身已经说明状态，弹框会遮挡内容
        addButton.toolTip = nil

        let row = PassthroughStackView(views: [name, code, L.spacer(), kindBadge, addButton])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.edgeInsets = NSEdgeInsets(top: 3, left: 5, bottom: 3, right: 4)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        // 不用手势识别器：它会抢走 NSButton 的点击事件。
        // 改用 mouseDown 手动分派，最可靠。


        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    @objc private func rowTapped() {
        onPreview(hit.security)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let btnFrame = convert(addButton.bounds, from: addButton)
        // 点在加号上：交给按钮（并给一点视觉反馈）
        if btnFrame.insetBy(dx: -3, dy: -3).contains(p) {
            if addButton.isEnabled {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.08
                    self.addButton.animator().alphaValue = 0.5
                } completionHandler: {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.12
                        self.addButton.animator().alphaValue = 1.0
                    }
                }
                addTapped()
            }
            return
        }
        // 其它区域：预览
        rowTapped()
    }

    @objc private func addTapped() {
        guard addButton.isEnabled else { return }
        onAdd(hit.security)
        addButton.title = "✓"
        addButton.contentTintColor = Theme.textFaint
        addButton.isEnabled = false
        addButton.toolTip = nil
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        layer?.backgroundColor = Theme.accent.withAlphaComponent(0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

}

// MARK: - 侧边栏

final class SidebarView: NSView {

    private let scroll = NSScrollView()
    private let listStack = NSStackView()
    private let searchField = NSSearchField()
    private let resultStack = NSStackView()
    private let resultContainer = NSView()
    private let previewBanner = RoundedBox(frame: .zero)
    private let previewLabel = L.label("", size: 9.5, color: Theme.text)
    private let previewAddButton = NSButton()
    private let statusDot = NSView()
    private let statusLabel = L.label("等待刷新", size: 9, color: Theme.textDim)
    private let countLabel = L.label("", size: 9, color: Theme.textFaint)
    private var rowViews: [String: WatchRowView] = [:]
    private var searchTask: Task<Void, Never>?
    private var signalMap: [String: (SignalKind, Double)] = [:]

    /// 搜索结果区域高度约束（有结果时展开）
    private var resultHeight: NSLayoutConstraint!
    /// 预览提示条高度约束（未自选时展开）
    private var bannerHeight: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.panel.cgColor
        build()
        observe()
        refreshAll()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func build() {
        // ===== 搜索框 =====
        searchField.placeholderString = "代码 / 名称 / 拼音"
        searchField.font = Fonts.ui(11)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.focusRingType = .none
        if let cell = searchField.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.sendsSearchStringImmediately = true
            cell.sendsActionOnEndEditing = false
        }
        searchField.target = self
        searchField.action = #selector(searchSubmitted)
        NotificationCenter.default.addObserver(self, selector: #selector(searchChanged),
                                              name: NSControl.textDidChangeNotification, object: searchField)

        // ===== 搜索结果 =====
        resultStack.orientation = .vertical
        resultStack.spacing = 1
        resultStack.alignment = .leading
        resultStack.translatesAutoresizingMaskIntoConstraints = false

        resultContainer.wantsLayer = true
        resultContainer.layer?.backgroundColor = Theme.panel2.cgColor
        resultContainer.layer?.cornerRadius = 5
        resultContainer.layer?.masksToBounds = true
        resultContainer.translatesAutoresizingMaskIntoConstraints = false
        resultContainer.isHidden = true

        // 最多展示 7 行，无需滚动，避免嵌套 NSScrollView 的布局死锁
        resultContainer.addSubview(resultStack)
        let rTop = resultStack.topAnchor.constraint(equalTo: resultContainer.topAnchor, constant: 2)
        let rBottom = resultStack.bottomAnchor.constraint(lessThanOrEqualTo: resultContainer.bottomAnchor, constant: -2)
        // 降低优先级，让容器的必需高度约束（0 或 N）优先，避免内部堆栈撑住容器
        rTop.priority = .defaultHigh
        rBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            rTop,
            resultStack.leadingAnchor.constraint(equalTo: resultContainer.leadingAnchor, constant: 2),
            resultStack.trailingAnchor.constraint(equalTo: resultContainer.trailingAnchor, constant: -2),
            rBottom
        ])

        // ===== 自选列表 =====
        listStack.orientation = .vertical
        listStack.spacing = 1
        listStack.alignment = .leading
        listStack.translatesAutoresizingMaskIntoConstraints = false

        // ===== 自选列头（标题 + 排序切换）=====
        let listHeader = buildListHeader()
        addSubview(listHeader)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // documentView 必须先有非零 frame，否则 AutoLayout 在首次布局时会递归
        let listDoc = FlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        listDoc.translatesAutoresizingMaskIntoConstraints = false
        listDoc.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.topAnchor.constraint(equalTo: listDoc.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: listDoc.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listDoc.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: listDoc.bottomAnchor)
        ])
        scroll.documentView = listDoc

        // ===== 预览提示条（当前看的票不在自选时显示）=====
        previewBanner.fillColor = Theme.accent.withAlphaComponent(0.10)
        previewBanner.borderColor = Theme.accent.withAlphaComponent(0.32)
        previewBanner.cornerRadius = 4
        previewBanner.translatesAutoresizingMaskIntoConstraints = false
        previewBanner.isHidden = true

        previewAddButton.title = "+ 自选"
        previewAddButton.setButtonType(.momentaryChange)
        previewAddButton.isBordered = false
        previewAddButton.attributedTitle = NSAttributedString(string: "+ 自选", attributes: [
            .font: Fonts.ui(9, weight: .semibold), .foregroundColor: Theme.buy
        ])
        previewAddButton.wantsLayer = true
        previewAddButton.layer?.backgroundColor = Theme.buy.withAlphaComponent(0.16).cgColor
        previewAddButton.layer?.cornerRadius = 3
        previewAddButton.target = self
        previewAddButton.action = #selector(addCurrentPreview)
        previewAddButton.translatesAutoresizingMaskIntoConstraints = false
        previewAddButton.heightAnchor.constraint(equalToConstant: 17).isActive = true
        previewAddButton.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let bannerRow = L.hstack([previewLabel, L.spacer(), previewAddButton], spacing: 5)
        previewBanner.addSubview(bannerRow)
        let bTop = bannerRow.topAnchor.constraint(equalTo: previewBanner.topAnchor, constant: 3)
        let bBottom = bannerRow.bottomAnchor.constraint(lessThanOrEqualTo: previewBanner.bottomAnchor, constant: -3)
        bTop.priority = .defaultHigh
        bBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            bTop, bBottom,
            bannerRow.leadingAnchor.constraint(equalTo: previewBanner.leadingAnchor, constant: 6),
            bannerRow.trailingAnchor.constraint(equalTo: previewBanner.trailingAnchor, constant: -5)
        ])

        // ===== 底部状态 =====
        statusDot.wantsLayer = true
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.layer?.cornerRadius = 2.5
        statusDot.layer?.backgroundColor = Theme.flat.cgColor
        statusDot.widthAnchor.constraint(equalToConstant: 5).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 5).isActive = true

        let statusRow = L.hstack([statusDot, statusLabel, L.spacer(), countLabel], spacing: 5)
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(searchField)
        addSubview(previewBanner)
        addSubview(resultContainer)
        addSubview(scroll)
        addSubview(divider)
        addSubview(statusRow)

        resultHeight = resultContainer.heightAnchor.constraint(equalToConstant: 0)
        resultHeight.isActive = true
        bannerHeight = previewBanner.heightAnchor.constraint(equalToConstant: 0)
        bannerHeight.isActive = true

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            searchField.heightAnchor.constraint(equalToConstant: 22),

            previewBanner.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 0),
            previewBanner.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            previewBanner.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),

            resultContainer.topAnchor.constraint(equalTo: previewBanner.bottomAnchor, constant: 0),
            resultContainer.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            resultContainer.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            resultHeight,

            listHeader.topAnchor.constraint(equalTo: resultContainer.bottomAnchor, constant: 2),
            listHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            listHeader.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            listHeader.heightAnchor.constraint(equalToConstant: 16),

            scroll.topAnchor.constraint(equalTo: listHeader.bottomAnchor, constant: 3),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -4),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: statusRow.topAnchor, constant: -4),

            statusRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            statusRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            statusRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            statusRow.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    private var sortButtons: [AppState.WatchSort: NSButton] = [:]

    private func buildListHeader() -> NSView {
        let title = L.label("自选", size: 9, weight: .semibold, color: Theme.textDim)
        title.setContentHuggingPriority(.required, for: .horizontal)

        var chips: [NSView] = []
        for sort in AppState.WatchSort.allCases {
            let b = NSButton(title: sort.label, target: self, action: #selector(sortTapped(_:)))
            b.setButtonType(.momentaryChange)
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 3
            b.font = Fonts.ui(8.5)
            b.tag = AppState.WatchSort.allCases.firstIndex(of: sort) ?? 0
            b.translatesAutoresizingMaskIntoConstraints = false
            b.heightAnchor.constraint(equalToConstant: 14).isActive = true
            sortButtons[sort] = b
            chips.append(b)
        }
        let chipRow = L.hstack(chips, spacing: 2)
        chipRow.setContentHuggingPriority(.required, for: .horizontal)

        let row = L.hstack([title, L.spacer(), chipRow], spacing: 4)
        row.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: host.topAnchor),
            row.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        updateSortChips()
        return host
    }

    @objc private func sortTapped(_ sender: NSButton) {
        let sort = AppState.WatchSort.allCases[sender.tag]
        AppState.shared.setWatchSort(sort)
        updateSortChips()
    }

    private func updateSortChips() {
        let current = AppState.shared.watchSort
        for (sort, b) in sortButtons {
            let active = (sort == current)
            b.attributedTitle = NSAttributedString(string: sort.label, attributes: [
                .font: Fonts.ui(8.5, weight: active ? .semibold : .regular),
                .foregroundColor: active ? NSColor.white : Theme.textFaint
            ])
            b.layer?.backgroundColor = active ? Theme.accent.withAlphaComponent(0.26).cgColor : NSColor.clear.cgColor
        }
    }

    private func observe() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(onQuotes), name: AppState.didChangeQuotes, object: nil)
        nc.addObserver(self, selector: #selector(onSelection), name: AppState.didChangeSelection, object: nil)
        nc.addObserver(self, selector: #selector(onStatus), name: AppState.didChangeStatus, object: nil)
        nc.addObserver(self, selector: #selector(onData), name: AppState.didChangeData, object: nil)
        nc.addObserver(self, selector: #selector(onWatchlist), name: AppState.didChangeWatchlist, object: nil)
        nc.addObserver(self, selector: #selector(onScan), name: AppState.didChangeScan, object: nil)
        nc.addObserver(self, selector: #selector(onFocusSearch), name: MainWindow.focusSearch, object: nil)
    }

    @objc private func addCurrentPreview() {
        AppState.shared.addCurrentToWatchlist()
        updatePreviewBanner()
    }

    /// 搜索框回车：代码直达；否则取第一个结果预览
    @objc private func searchSubmitted() {
        let kw = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }

        // 纯数字/纯ASCII字母 → 认为是代码，直接预览
        let isNumeric = kw.allSatisfy(\.isNumber)
        let isASCIIAlpha = kw.allSatisfy { ch in
            guard let a = ch.asciiValue else { return false }
            return (65...90).contains(a) || (97...122).contains(a) || a == 46 || a == 45
        }
        if isNumeric || isASCIIAlpha, let sec = SecurityFactory.fromRawInput(kw) {
            AppState.shared.preview(sec)
            // 同时把搜索结果列出来，方便加自选
            Task { [weak self] in
                let hits = await SecuritySearchService.shared.search(kw)
                await MainActor.run { self?.showResults(hits) }
            }
            return
        }

        // 中文/拼音 → 必须先搜索，取第一个结果
        Task { [weak self] in
            let hits = await SecuritySearchService.shared.search(kw)
            await MainActor.run {
                self?.showResults(hits)
                if let first = hits.first {
                    AppState.shared.preview(first.security)
                }
            }
        }
    }

    /// 刷新"未自选"提示条
    private func updatePreviewBanner() {
        let app = AppState.shared
        guard let cur = app.selected else {
            previewBanner.isHidden = true
            return
        }
        let inList = app.isCurrentInWatchlist
        previewBanner.isHidden = inList
        bannerHeight.constant = inList ? 0 : 25
        needsLayout = true
        if !inList {
            previewLabel.stringValue = "\(cur.name.isEmpty ? cur.displayCode : cur.name) 未自选"
            previewAddButton.isEnabled = true
        }
    }

    @objc private func onFocusSearch() {
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    @objc private func onQuotes() { updateQuotes() }
    @objc private func onSelection() {
        updateSelection()
        updatePreviewBanner()
    }
    @objc private func onStatus() { updateStatus() }
    @objc private func onData() { updateStatus() }
    @objc private func onWatchlist() {
        rebuildList()
        updatePreviewBanner()
        updateSortChips()
    }
    @objc private func onScan() { updateSignals() }

    // MARK: - 刷新

    private func refreshAll() {
        rebuildList()
        updateQuotes()
        updateSelection()
        updateStatus()
        updatePreviewBanner()
    }

    private func rebuildList() {
        for v in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        rowViews.removeAll()

        let app = AppState.shared
        for item in app.sortedWatchlist {
            let row = WatchRowView(item: item, onSelect: { id in
                AppState.shared.select(id)
            }, onRemove: { id in
                AppState.shared.remove(id)
            })
            row.translatesAutoresizingMaskIntoConstraints = false
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            rowViews[item.id] = row
        }
        countLabel.stringValue = "\(app.watchlist.count) 只"
        updateSelection()
        updateQuotes()
        updateSignals()
    }

    private func updateQuotes() {
        let app = AppState.shared
        for (id, row) in rowViews {
            row.update(quote: app.quotes[id])
        }
    }

    private func updateSelection() {
        let app = AppState.shared
        let currentID = app.selected?.id
        for (id, row) in rowViews {
            row.setSelected(id == currentID)
        }
    }

    private func updateSignals() {
        let app = AppState.shared
        for (id, row) in rowViews {
            if let s = app.scanResults.first(where: { $0.security.id == id }) {
                row.setSignal(kind: s.bestKind, score: s.bestScore)
            } else {
                row.setSignal(kind: nil, score: 0)
            }
        }
    }

    private func updateStatus() {
        let app = AppState.shared
        if let err = app.errorMessage {
            statusLabel.stringValue = err
            statusDot.layer?.backgroundColor = Theme.risk.cgColor
        } else if app.isLoading {
            statusLabel.stringValue = "加载中…"
            statusDot.layer?.backgroundColor = Theme.accent.cgColor
        } else if let t = app.lastUpdate {
            statusLabel.stringValue = "更新 \(Fmt.intradayFormatter.string(from: t))"
            statusDot.layer?.backgroundColor = Theme.buy.cgColor
        } else {
            statusLabel.stringValue = "等待刷新"
            statusDot.layer?.backgroundColor = Theme.flat.cgColor
        }
    }

    // MARK: - 搜索

    @objc private func searchChanged() {
        let kw = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !kw.isEmpty else {
            hideResults()
            return
        }
        // 输入变化时把提示条先藏起来，避免抢视觉（高度必须一起归零，否则留空）
        if !AppState.shared.isCurrentInWatchlist {
            previewBanner.isHidden = true
            bannerHeight.constant = 0
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard !Task.isCancelled else { return }
            let hits = await SecuritySearchService.shared.search(kw)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.showResults(hits) }
        }
    }

    private func hideResults() {
        for v in resultStack.arrangedSubviews {
            resultStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        resultContainer.isHidden = true
        resultHeight.constant = 0
        needsLayout = true
    }

    private func showResults(_ hits: [SearchHit]) {
        for v in resultStack.arrangedSubviews {
            resultStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        guard !hits.isEmpty else {
            let empty = L.label("无匹配结果", size: 10, color: Theme.textFaint)
            empty.alignment = .center
            resultStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: resultStack.widthAnchor).isActive = true
            empty.heightAnchor.constraint(equalToConstant: 24).isActive = true
            resultContainer.isHidden = false
            resultHeight.constant = 32
            return
        }

        let existing = Set(AppState.shared.watchlist.map(\.id))
        for hit in hits {
            let row = SearchHitRow(
                hit: hit,
                alreadyAdded: existing.contains(hit.security.id),
                onPreview: { [weak self] sec in
                    // 点整行 = 只切图看，不加入自选，并收起结果（同花顺行为）
                    AppState.shared.preview(sec)
                    self?.hideResults()
                },
                onAdd: { sec in
                    // 点 + = 加入自选
                    AppState.shared.add(sec)
                }
            )
            row.translatesAutoresizingMaskIntoConstraints = false
            resultStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: resultStack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }

        resultContainer.isHidden = false
        let visibleRows = min(hits.count, 7)
        resultHeight.constant = CGFloat(visibleRows) * 23 + 6
        // 强制立即布局，避免高度滞后一帧
        needsLayout = true
    }
}
