import AppKit

// MARK: - 扫描列表行

final class ScanRowView: NSView {
    private let result: ScanResult
    private let rank: Int
    private let verdict: AIVerdict?
    private let onSelect: (Security) -> Void
    private var hovered = false

    init(result: ScanResult, rank: Int, verdict: AIVerdict?, onSelect: @escaping (Security) -> Void) {
        self.result = result
        self.rank = rank
        self.verdict = verdict
        self.onSelect = onSelect
        super.init(frame: .zero)
        build()
        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(click)
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    @objc private func tapped() { onSelect(result.security) }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.045).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// 依据截断：行内只放得下前 14 字，超长加省略号
    private func shortReason(_ reason: String) -> String {
        reason.count > 14 ? String(reason.prefix(14)) + "…" : reason
    }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 4

        // 排名徽章
        let rankLabel = L.label("\(rank)", size: 9, weight: .bold, color: Theme.textFaint, mono: true)
        rankLabel.alignment = .center
        rankLabel.widthAnchor.constraint(equalToConstant: 14).isActive = true

        // 名称 + 代码
        let name = L.label(result.security.name.isEmpty ? result.security.displayCode : result.security.name,
                           size: 11, weight: .medium)
        let code = L.label(result.security.displayCode, size: 8, color: Theme.textFaint, mono: true)
        let nameCol = L.vstack([name, code], spacing: 0)
        nameCol.alignment = .leading

        // 机会分
        let scoreColor: NSColor
        if result.opportunityScore >= 60 { scoreColor = Theme.buy }
        else if result.opportunityScore >= 40 { scoreColor = Theme.risk }
        else { scoreColor = Theme.textFaint }
        let score = L.label(String(format: "%.0f", result.opportunityScore),
                            size: 13, weight: .bold, color: scoreColor, mono: true)
        score.alignment = .right
        score.widthAnchor.constraint(equalToConstant: 26).isActive = true

        // 分级标签（比信号标签更重要，放在最左）
        let gradeColor: NSColor
        switch result.grade {
        case .strong: gradeColor = Theme.buy
        case .buy: gradeColor = Theme.buy.withAlphaComponent(0.85)
        case .watch: gradeColor = Theme.risk
        case .none: gradeColor = Theme.textFaint
        case .avoid: gradeColor = Theme.distribute
        }
        let gradeBadge = NSTextField(labelWithString: result.grade.rawValue)
        gradeBadge.font = Fonts.ui(7.5, weight: .semibold)
        gradeBadge.textColor = gradeColor
        gradeBadge.wantsLayer = true
        gradeBadge.layer?.backgroundColor = gradeColor.withAlphaComponent(0.16).cgColor
        gradeBadge.layer?.cornerRadius = 2
        gradeBadge.alignment = .center
        gradeBadge.translatesAutoresizingMaskIntoConstraints = false
        gradeBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        gradeBadge.heightAnchor.constraint(equalToConstant: 13).isActive = true

        // 信号标签
        var signalView: NSView = NSView()
        if let kind = result.bestKind, result.bestScore >= 55 {
            let color = Theme.color(for: kind)
            let badge = NSTextField(labelWithString: kind.label)
            badge.font = Fonts.ui(7.5, weight: .medium)
            badge.textColor = color
            badge.wantsLayer = true
            badge.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
            badge.layer?.cornerRadius = 2
            badge.alignment = .center
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
            badge.heightAnchor.constraint(equalToConstant: 13).isActive = true
            signalView = badge
        }

        // AI 结论
        if let v = verdict {
            let c: NSColor
            switch v.action {
            case "强烈买入": c = Theme.buy
            case "买入": c = Theme.accent
            case "观察": c = Theme.risk
            case "回避": c = Theme.textFaint
            default: c = Theme.distribute
            }
            let badge = NSTextField(labelWithString: v.action)
            badge.font = Fonts.ui(7.5, weight: .semibold)
            badge.textColor = c
            badge.wantsLayer = true
            badge.layer?.backgroundColor = c.withAlphaComponent(0.15).cgColor
            badge.layer?.cornerRadius = 2
            badge.alignment = .center
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
            badge.heightAnchor.constraint(equalToConstant: 13).isActive = true
            let combined = NSStackView(views: [gradeBadge, signalView, badge])
            combined.orientation = .horizontal
            combined.spacing = 3
            combined.translatesAutoresizingMaskIntoConstraints = false
            signalView = combined
        } else {
            signalView = gradeBadge
        }

        let topLeft = L.hstack([rankLabel, nameCol], spacing: 5)
        let topRight = L.hstack([signalView, L.spacer(), score], spacing: 4)
        let topRow = L.hstack([topLeft, L.spacer(), topRight], spacing: 6)

        // 结论行
        let verdictText = verdict?.thesis.isEmpty == false ? (verdict?.thesis ?? "") : result.verdict
        let sub = L.label(verdictText, size: 8.5,
                          color: verdict != nil ? Theme.text.withAlphaComponent(0.72) : Theme.textDim)
        sub.lineBreakMode = .byTruncatingTail

        // 关键价位
        var priceParts: [String] = []
        if let zone = result.entryZone {
            priceParts.append("入 \(Fmt.price(zone.low))~\(Fmt.price(zone.high))")
        }
        if let stop = verdict?.stopLoss ?? nil {
            priceParts.append("损 \(Fmt.price(stop))")
        } else if let s = result.support {
            priceParts.append("撑 \(Fmt.price(s))")
        }
        if let t = verdict?.target ?? result.resistance {
            priceParts.append("标 \(Fmt.price(t))")
        }
        if let rr = result.riskReward, rr > 0 {
            priceParts.append(String(format: "比 %.1f", rr))
        }
        let priceRow = L.label(priceParts.joined(separator: "  "), size: 8,
                               color: Theme.textFaint, mono: true)

        // 买卖点记录：最近一条买点 + 最近一条卖点（价格 · 日期 · 依据）
        var rows: [NSView] = [topRow, sub, priceRow]
        let latestBuy = result.tradePoints.filter { $0.direction == .buy }.max { $0.date < $1.date }
        let latestSell = result.tradePoints.filter { $0.direction == .sell }.max { $0.date < $1.date }
        var tpParts: [String] = []
        if let b = latestBuy {
            tpParts.append("买 \(Fmt.price(b.price)) \(Fmt.shortDateFormatter.string(from: b.date)) \(shortReason(b.reason))")
        }
        if let s = latestSell {
            tpParts.append("卖 \(Fmt.price(s.price)) \(Fmt.shortDateFormatter.string(from: s.date)) \(shortReason(s.reason))")
        }
        if !tpParts.isEmpty {
            let tpRow = L.label(tpParts.joined(separator: "   "), size: 8, color: Theme.textDim)
            tpRow.lineBreakMode = .byTruncatingTail
            rows.append(tpRow)
        }

        let col = L.vstack(rows, spacing: 1)
        col.alignment = .leading
        addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            col.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7)
        ])
        for v in rows {
            v.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        }

        // 左侧机会色条
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = gradeColor.withAlphaComponent(0.75).cgColor
        bar.layer?.cornerRadius = 1
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            bar.widthAnchor.constraint(equalToConstant: 2)
        ])
    }
}

// MARK: - 扫描面板

final class ScanPanel: PanelBase {

    private let body = FlippedStackView()
    private var scroll: NSScrollView!
    private let scanButton = NSButton()
    private let aiButton = NSButton()
    private let statusLabel = L.label("未扫描", size: 8.5, color: Theme.textFaint)
    private let progress = NSProgressIndicator()

    init() {
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 4
        super.init(title: "开盘扫描", icon: "antenna.radiowaves.left.and.right")

        // 按钮
        scanButton.title = "扫描"
        scanButton.setButtonType(.momentaryChange)
        scanButton.isBordered = false
        scanButton.attributedTitle = NSAttributedString(string: "扫描", attributes: [
            .font: Fonts.ui(9.5, weight: .medium), .foregroundColor: NSColor.white
        ])
        scanButton.wantsLayer = true
        scanButton.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.30).cgColor
        scanButton.layer?.cornerRadius = 3
        scanButton.target = self
        scanButton.action = #selector(doScan)
        scanButton.translatesAutoresizingMaskIntoConstraints = false
        scanButton.heightAnchor.constraint(equalToConstant: 17).isActive = true
        scanButton.widthAnchor.constraint(equalToConstant: 38).isActive = true

        aiButton.title = "AI"
        aiButton.setButtonType(.momentaryChange)
        aiButton.isBordered = false
        aiButton.attributedTitle = NSAttributedString(string: "AI", attributes: [
            .font: Fonts.ui(9.5, weight: .semibold), .foregroundColor: NSColor.white
        ])
        aiButton.wantsLayer = true
        aiButton.layer?.backgroundColor = Theme.buy.withAlphaComponent(0.28).cgColor
        aiButton.layer?.cornerRadius = 3
        aiButton.target = self
        aiButton.action = #selector(doAI)
        aiButton.translatesAutoresizingMaskIntoConstraints = false
        aiButton.heightAnchor.constraint(equalToConstant: 17).isActive = true
        aiButton.widthAnchor.constraint(equalToConstant: 26).isActive = true

        progress.style = .bar
        progress.isIndeterminate = false
        progress.controlSize = .small
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.isHidden = true
        progress.heightAnchor.constraint(equalToConstant: 3).isActive = true

        body.orientation = .vertical
        body.spacing = 1
        body.alignment = .leading

        scroll = makeScrollable(body)
        addBody(scroll)
        // 固定可视高度：扫描结果最多 10 行，超出靠滚动
        scroll.heightAnchor.constraint(equalToConstant: 168).isActive = true

        let footer = L.hstack([statusLabel, L.spacer(), progress], spacing: 6)
        addBody(footer)
        footer.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        progress.widthAnchor.constraint(equalToConstant: 60).isActive = true

        // 按钮放在标题栏右侧
        let headRow = L.hstack([aiButton, scanButton], spacing: 4)
        addHeaderAccessory(headRow)

        observe()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func observe() {
        NotificationCenter.default.addObserver(self, selector: #selector(onScan),
                                              name: AppState.didChangeScan, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onAI),
                                              name: AppState.didChangeAI, object: nil)
    }

    @objc private func onScan() { refresh() }
    @objc private func onAI() { refresh() }

    @objc private func doScan() {
        AppState.shared.startScan(includeAI: false)
    }

    @objc private func doAI() {
        let app = AppState.shared
        if !app.aiConfig.isUsable {
            NotificationCenter.default.post(name: AppState.didRequestAISettings, object: nil)
            return
        }
        if app.scanResults.isEmpty {
            app.startScan(includeAI: true)
        } else {
            Task { await app.runAIReview() }
        }
    }

    func refresh() {
        for v in body.arrangedSubviews {
            body.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        let app = AppState.shared

        // 状态
        if app.isScanning {
            let p = app.scanProgress
            let pct = p.total > 0 ? Double(p.done) / Double(p.total) * 100 : 0
            statusLabel.stringValue = "扫描中 \(p.done)/\(p.total)"
            statusLabel.textColor = Theme.accent
            progress.isHidden = false
            progress.doubleValue = pct
        } else if app.isAIReviewing {
            statusLabel.stringValue = "AI 复核中…"
            statusLabel.textColor = Theme.buy
            progress.isHidden = true
        } else if let err = app.aiLastError {
            statusLabel.stringValue = err
            statusLabel.textColor = Theme.distribute
            progress.isHidden = true
        } else if let t = app.lastScanAt {
            statusLabel.stringValue = "\(app.scanResults.count) 只 · \(Fmt.intradayFormatter.string(from: t))"
            statusLabel.textColor = Theme.textFaint
            progress.isHidden = true
        } else {
            statusLabel.stringValue = "未扫描"
            statusLabel.textColor = Theme.textFaint
            progress.isHidden = true
        }

        if app.scanResults.isEmpty {
            let hint = L.label(app.isScanning ? "正在分析自选股…" : "点「扫描」分析全部自选股",
                               size: 9, color: Theme.textFaint)
            body.addArrangedSubview(hint)
            hint.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            if !app.aiConfig.isUsable && !app.isScanning {
                let aiHint = L.label("配置 AI 可获得二次确认", size: 8, color: Theme.textFaint)
                body.addArrangedSubview(aiHint)
                aiHint.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            }
            return
        }

        for (i, r) in app.scanResults.prefix(10).enumerated() {
            let verdict = app.aiVerdicts[r.security.displayCode]
            let row = ScanRowView(result: r, rank: i + 1, verdict: verdict) { sec in
                // 点扫描结果 = 预览看图（不加入自选）
                AppState.shared.preview(sec)
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            body.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
            // 有买卖点记录时多一行，行高相应增加
            row.heightAnchor.constraint(equalToConstant: r.tradePoints.isEmpty ? 54 : 66).isActive = true
        }
    }
}

// MARK: - AI 设置面板

final class AISettingsPanel: PanelBase {

    private let enableSwitch = NSSwitch()
    private let baseURLField = NSTextField()
    private let keyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let testButton = NSButton()
    private let resultLabel = L.label("", size: 8.5, color: Theme.textFaint)
    private let maxCandidates = NSTextField()

    // 本地模型（Ollama）区：只做信号解释，默认关闭
    private let localEnableSwitch = NSSwitch()
    private let localBaseURLField = NSTextField()
    private let localModelField = NSTextField()
    private let localTestButton = NSButton()
    private let localResultLabel = L.label("", size: 8.5, color: Theme.textFaint)

    private let cloudEnableSwitch = NSSwitch()
    private let cloudPresetPopup = NSPopUpButton()
    private let cloudBaseURLField = NSTextField()
    private let cloudModelField = NSTextField()
    private let cloudKeyField = NSSecureTextField()
    private let cloudTestButton = NSButton()
    private let cloudResultLabel = L.label("", size: 8.5, color: Theme.textFaint)
    private let cloudKeyStateLabel = L.label("", size: 8.5, color: Theme.textFaint)

    init() {
        super.init(title: "AI 接入", icon: "sparkles")
        build()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    private func smallField(_ placeholder: String, secure: Bool = false) -> NSTextField {
        let f: NSTextField = secure ? NSSecureTextField() : NSTextField()
        f.placeholderString = placeholder
        f.font = Fonts.mono(10)
        f.isBordered = true
        f.bezelStyle = .roundedBezel
        f.focusRingType = .none
        f.translatesAutoresizingMaskIntoConstraints = false
        f.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return f
    }

    private func build() {
        let cfg = AppState.shared.aiConfig

        // 开关行
        enableSwitch.state = cfg.enabled ? .on : .off

        enableSwitch.controlSize = .small
        enableSwitch.target = self
        enableSwitch.action = #selector(save)
        enableSwitch.translatesAutoresizingMaskIntoConstraints = false
        let enableRow = L.hstack([L.label("启用", size: 9.5, color: Theme.textDim), L.spacer(), enableSwitch], spacing: 4)
        addBody(enableRow)
        enableRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        // Base URL
        baseURLField.placeholderString = "https://api.openai.com/v1"
        baseURLField.font = Fonts.mono(9.5)
        baseURLField.isBordered = true
        baseURLField.bezelStyle = .roundedBezel
        baseURLField.focusRingType = .none
        baseURLField.stringValue = cfg.baseURL
        baseURLField.translatesAutoresizingMaskIntoConstraints = false
        baseURLField.heightAnchor.constraint(equalToConstant: 20).isActive = true
        baseURLField.target = self
        baseURLField.action = #selector(save)
        addField("Base URL", baseURLField)

        // API Key
        keyField.placeholderString = "sk-..."
        keyField.font = Fonts.mono(9.5)
        keyField.isBordered = true
        keyField.bezelStyle = .roundedBezel
        keyField.focusRingType = .none
        keyField.stringValue = cfg.apiKey
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.heightAnchor.constraint(equalToConstant: 20).isActive = true
        keyField.target = self
        keyField.action = #selector(save)
        addField("API Key", keyField)

        // Model
        modelField.placeholderString = "gpt-4o-mini"
        modelField.font = Fonts.mono(9.5)
        modelField.isBordered = true
        modelField.bezelStyle = .roundedBezel
        modelField.focusRingType = .none
        modelField.stringValue = cfg.model
        modelField.translatesAutoresizingMaskIntoConstraints = false
        modelField.heightAnchor.constraint(equalToConstant: 20).isActive = true
        modelField.target = self
        modelField.action = #selector(save)
        addField("模型", modelField)

        // 送审数量
        maxCandidates.placeholderString = "5"
        maxCandidates.font = Fonts.mono(9.5)
        maxCandidates.isBordered = true
        maxCandidates.bezelStyle = .roundedBezel
        maxCandidates.focusRingType = .none
        maxCandidates.stringValue = "\(cfg.maxCandidatesPerScan)"
        maxCandidates.translatesAutoresizingMaskIntoConstraints = false
        maxCandidates.heightAnchor.constraint(equalToConstant: 20).isActive = true
        maxCandidates.target = self
        maxCandidates.action = #selector(save)
        addField("每次送审只数", maxCandidates)

        // 测试
        testButton.title = "测试连接"
        testButton.setButtonType(.momentaryChange)
        testButton.isBordered = false
        testButton.attributedTitle = NSAttributedString(string: "测试连接", attributes: [
            .font: Fonts.ui(9.5), .foregroundColor: Theme.accent
        ])
        testButton.wantsLayer = true
        testButton.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.13).cgColor
        testButton.layer?.cornerRadius = 3
        testButton.target = self
        testButton.action = #selector(testConnection)
        testButton.translatesAutoresizingMaskIntoConstraints = false
        testButton.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let testRow = L.hstack([testButton, L.spacer(), resultLabel], spacing: 6)
        addBody(testRow)
        testRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let hint = L.wrapped("兼容 OpenAI / DeepSeek / Moonshot / 本地 Ollama 等 Chat Completions 接口。Key 只存本机 UserDefaults。",
                             size: 8, color: Theme.textFaint)
        NotificationCenter.default.addObserver(self, selector: #selector(onAIChanged),
                                              name: AppState.didChangeAI, object: nil)
        hint.preferredMaxLayoutWidth = 270
        addBody(hint)
        hint.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        resultLabel.stringValue = AppState.shared.aiStatus.isEmpty ? "" : AppState.shared.aiStatus

        buildLocalLLMSection()
        buildCloudLLMSection()
    }

    // MARK: - 本地模型（Ollama）区

    private func buildLocalLLMSection() {
        let cfg = AppState.shared.localLLMConfig

        let divider = L.label("本地模型解释（Ollama）", size: 9, weight: .semibold, color: Theme.textDim)
        addBody(divider)
        divider.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        localEnableSwitch.state = cfg.enabled ? .on : .off
        localEnableSwitch.controlSize = .small
        localEnableSwitch.target = self
        localEnableSwitch.action = #selector(saveLocalLLM)
        localEnableSwitch.translatesAutoresizingMaskIntoConstraints = false
        let enableRow = L.hstack([L.label("启用本地解释", size: 9.5, color: Theme.textDim), L.spacer(), localEnableSwitch], spacing: 4)
        addBody(enableRow)
        enableRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        localBaseURLField.placeholderString = "http://localhost:11434/v1"
        localBaseURLField.font = Fonts.mono(9.5)
        localBaseURLField.isBordered = true
        localBaseURLField.bezelStyle = .roundedBezel
        localBaseURLField.focusRingType = .none
        localBaseURLField.stringValue = cfg.baseURL
        localBaseURLField.translatesAutoresizingMaskIntoConstraints = false
        localBaseURLField.heightAnchor.constraint(equalToConstant: 20).isActive = true
        localBaseURLField.target = self
        localBaseURLField.action = #selector(saveLocalLLM)
        addField("Ollama 地址", localBaseURLField)

        localModelField.placeholderString = "qwen2.5:3b"
        localModelField.font = Fonts.mono(9.5)
        localModelField.isBordered = true
        localModelField.bezelStyle = .roundedBezel
        localModelField.focusRingType = .none
        localModelField.stringValue = cfg.model
        localModelField.translatesAutoresizingMaskIntoConstraints = false
        localModelField.heightAnchor.constraint(equalToConstant: 20).isActive = true
        localModelField.target = self
        localModelField.action = #selector(saveLocalLLM)
        addField("模型", localModelField)

        localTestButton.title = "测试本地端点"
        localTestButton.setButtonType(.momentaryChange)
        localTestButton.isBordered = false
        localTestButton.attributedTitle = NSAttributedString(string: "测试本地端点", attributes: [
            .font: Fonts.ui(9.5), .foregroundColor: Theme.accent
        ])
        localTestButton.wantsLayer = true
        localTestButton.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.13).cgColor
        localTestButton.layer?.cornerRadius = 3
        localTestButton.target = self
        localTestButton.action = #selector(testLocalLLM)
        localTestButton.translatesAutoresizingMaskIntoConstraints = false
        localTestButton.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let localTestRow = L.hstack([localTestButton, L.spacer(), localResultLabel], spacing: 6)
        addBody(localTestRow)
        localTestRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let localHint = L.wrapped("本地模型只解释规则算好的信号，不参与决策、不新增信号。需自行安装 Ollama 并 pull 模型（8GB 内存建议 qwen2.5:3b，7B 会卡顿）。端点不通或输出校验失败时自动回落模板文字。模型会编造、算术不可靠，以数字为准。",
                                  size: 8, color: Theme.textFaint)
        localHint.preferredMaxLayoutWidth = 270
        addBody(localHint)
        localHint.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    @objc private func saveLocalLLM() {
        var cfg = AppState.shared.localLLMConfig
        cfg.enabled = localEnableSwitch.state == .on
        cfg.baseURL = localBaseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.model = localModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        AppState.shared.saveLocalLLMConfig(cfg)
    }

    @objc private func testLocalLLM() {
        saveLocalLLM()
        let cfg = AppState.shared.localLLMConfig
        guard cfg.isUsable else {
            localResultLabel.stringValue = "✗ 请先启用开关并填写模型名"
            localResultLabel.textColor = Theme.distribute
            return
        }
        localResultLabel.stringValue = "测试中…"
        localResultLabel.textColor = Theme.textDim
        Task { @MainActor in
            let ok = await LocalLLMClient.shared.checkAvailable(config: cfg)
            self.localResultLabel.stringValue = ok ? "✓ 本地端点连通" : "✗ 端点不通（Ollama 未启动？）"
            self.localResultLabel.textColor = ok ? Theme.buy : Theme.distribute
        }
    }

    // MARK: - 云端模型区

    private func buildCloudLLMSection() {
        let cfg = AppState.shared.cloudLLMConfig

        let divider = L.label("云端模型解释（DeepSeek / 通义）", size: 9, weight: .semibold, color: Theme.textDim)
        addBody(divider)
        divider.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        cloudEnableSwitch.state = cfg.enabled ? .on : .off
        cloudEnableSwitch.controlSize = .small
        cloudEnableSwitch.target = self
        cloudEnableSwitch.action = #selector(saveCloudLLM)
        cloudEnableSwitch.translatesAutoresizingMaskIntoConstraints = false
        let enableRow = L.hstack([L.label("启用云端解释", size: 9.5, color: Theme.textDim), L.spacer(), cloudEnableSwitch], spacing: 4)
        addBody(enableRow)
        enableRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        var presetTitles: [String] = []
        for p in CloudLLMConfig.Preset.allCases { presetTitles.append(p.label) }
        cloudPresetPopup.addItems(withTitles: presetTitles)
        cloudPresetPopup.controlSize = .small
        cloudPresetPopup.font = Fonts.ui(9.5)
        cloudPresetPopup.target = self
        cloudPresetPopup.action = #selector(saveCloudLLM)
        cloudPresetPopup.translatesAutoresizingMaskIntoConstraints = false
        cloudPresetPopup.heightAnchor.constraint(equalToConstant: 20).isActive = true
        var presetIndex = 0
        for (i, p) in CloudLLMConfig.Preset.allCases.enumerated() {
            if p == cfg.preset { presetIndex = i }
        }
        cloudPresetPopup.selectItem(at: presetIndex)
        let presetRow = L.hstack([L.label("服务商", size: 9.5, color: Theme.textDim), L.spacer(), cloudPresetPopup], spacing: 4)
        addBody(presetRow)
        presetRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        cloudBaseURLField.placeholderString = "https://api.deepseek.com/v1"
        cloudBaseURLField.font = Fonts.mono(9.5)
        cloudBaseURLField.isBordered = true
        cloudBaseURLField.bezelStyle = .roundedBezel
        cloudBaseURLField.focusRingType = .none
        cloudBaseURLField.stringValue = cfg.baseURL
        cloudBaseURLField.translatesAutoresizingMaskIntoConstraints = false
        cloudBaseURLField.heightAnchor.constraint(equalToConstant: 20).isActive = true
        cloudBaseURLField.target = self
        cloudBaseURLField.action = #selector(saveCloudLLM)
        addField("接口地址", cloudBaseURLField)

        cloudModelField.placeholderString = "deepseek-chat"
        cloudModelField.font = Fonts.mono(9.5)
        cloudModelField.isBordered = true
        cloudModelField.bezelStyle = .roundedBezel
        cloudModelField.focusRingType = .none
        cloudModelField.stringValue = cfg.model
        cloudModelField.translatesAutoresizingMaskIntoConstraints = false
        cloudModelField.heightAnchor.constraint(equalToConstant: 20).isActive = true
        cloudModelField.target = self
        cloudModelField.action = #selector(saveCloudLLM)
        addField("模型", cloudModelField)

        cloudKeyField.placeholderString = "API Key（保存后存入系统钥匙串）"
        cloudKeyField.font = Fonts.mono(9.5)
        cloudKeyField.isBordered = true
        cloudKeyField.bezelStyle = .roundedBezel
        cloudKeyField.focusRingType = .none
        cloudKeyField.translatesAutoresizingMaskIntoConstraints = false
        cloudKeyField.heightAnchor.constraint(equalToConstant: 20).isActive = true
        cloudKeyField.target = self
        cloudKeyField.action = #selector(saveCloudLLM)
        addField("API Key", cloudKeyField)

        let keyStateRow = L.hstack([cloudKeyStateLabel, L.spacer()], spacing: 4)
        addBody(keyStateRow)
        keyStateRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        refreshCloudKeyState()

        cloudTestButton.title = "测试云端连接"
        cloudTestButton.setButtonType(.momentaryChange)
        cloudTestButton.isBordered = false
        cloudTestButton.attributedTitle = NSAttributedString(string: "测试云端连接", attributes: [
            .font: Fonts.ui(9.5), .foregroundColor: Theme.accent
        ])
        cloudTestButton.wantsLayer = true
        cloudTestButton.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.13).cgColor
        cloudTestButton.layer?.cornerRadius = 3
        cloudTestButton.target = self
        cloudTestButton.action = #selector(testCloudLLM)
        cloudTestButton.translatesAutoresizingMaskIntoConstraints = false
        cloudTestButton.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let cloudTestRow = L.hstack([cloudTestButton, L.spacer(), cloudResultLabel], spacing: 6)
        addBody(cloudTestRow)
        cloudTestRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let cloudHint = L.wrapped("云端模型只解释规则算好的信号，不参与决策、不新增信号；与本地模型同一套数字校验，失败时回落模板文字。Key 只存系统钥匙串，界面不回显。信号数据会发给所选服务商，费用自付。本地与云端同时开启时优先用云端。首次保存 Key 时系统可能要求钥匙串访问权限。",
                                  size: 8, color: Theme.textFaint)
        cloudHint.preferredMaxLayoutWidth = 270
        addBody(cloudHint)
        cloudHint.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    private func refreshCloudKeyState() {
        if CloudLLMConfig.hasKey() {
            cloudKeyStateLabel.stringValue = "Key 已保存到系统钥匙串（重新填写可覆盖）"
            cloudKeyStateLabel.textColor = Theme.buy
        } else {
            cloudKeyStateLabel.stringValue = "未保存 Key"
            cloudKeyStateLabel.textColor = Theme.textFaint
        }
    }

    @objc private func saveCloudLLM() {
        var cfg = AppState.shared.cloudLLMConfig
        cfg.enabled = cloudEnableSwitch.state == .on
        let presets = CloudLLMConfig.Preset.allCases
        let selIndex = cloudPresetPopup.indexOfSelectedItem
        var preset = CloudLLMConfig.Preset.custom
        if selIndex >= 0 && selIndex < presets.count {
            preset = presets[selIndex]
        }
        cfg.preset = preset
        if preset == .custom {
            cfg.baseURL = cloudBaseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            cfg.model = cloudModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            cfg.baseURL = preset.baseURL
            cfg.model = preset.model
            cloudBaseURLField.stringValue = cfg.baseURL
            cloudModelField.stringValue = cfg.model
        }
        AppState.shared.saveCloudLLMConfig(cfg)
        // Key 只进钥匙串：填了就存，存完立即清空输入框，绝不回显
        let key = cloudKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            _ = CloudLLMConfig.saveKey(key)
            cloudKeyField.stringValue = ""
        }
        refreshCloudKeyState()
    }

    @objc private func testCloudLLM() {
        saveCloudLLM()
        let cfg = AppState.shared.cloudLLMConfig
        guard let key = CloudLLMConfig.loadKey(), !key.isEmpty else {
            cloudResultLabel.stringValue = "✗ 请先填写并保存 API Key"
            cloudResultLabel.textColor = Theme.distribute
            return
        }
        guard cfg.isUsable else {
            cloudResultLabel.stringValue = "✗ 请先启用开关并填写模型名"
            cloudResultLabel.textColor = Theme.distribute
            return
        }
        cloudResultLabel.stringValue = "测试中…"
        cloudResultLabel.textColor = Theme.textDim
        Task { @MainActor in
            let ok = await CloudLLMClient.shared.checkAvailable(config: cfg, apiKey: key)
            self.cloudResultLabel.stringValue = ok ? "✓ 云端连通，Key 有效" : "✗ 连通失败（地址、Key 或网络）"
            self.cloudResultLabel.textColor = ok ? Theme.buy : Theme.distribute
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 供主窗口调用：配置变了就回填
    func syncIfNeeded() { syncFromConfig() }

    /// 把存储的配置回填到控件（配置可能被外部修改或清除）
    private func syncFromConfig() {
        let cfg = AppState.shared.aiConfig
        enableSwitch.state = cfg.enabled ? .on : .off
        if baseURLField.currentEditor() == nil { baseURLField.stringValue = cfg.baseURL }
        if keyField.currentEditor() == nil { keyField.stringValue = cfg.apiKey }
        if modelField.currentEditor() == nil { modelField.stringValue = cfg.model }
        if maxCandidates.currentEditor() == nil { maxCandidates.stringValue = "\(cfg.maxCandidatesPerScan)" }
        let local = AppState.shared.localLLMConfig
        localEnableSwitch.state = local.enabled ? .on : .off
        if localBaseURLField.currentEditor() == nil { localBaseURLField.stringValue = local.baseURL }
        if localModelField.currentEditor() == nil { localModelField.stringValue = local.model }
        let cloud = AppState.shared.cloudLLMConfig
        cloudEnableSwitch.state = cloud.enabled ? .on : .off
        var cloudIndex = 0
        for (i, p) in CloudLLMConfig.Preset.allCases.enumerated() {
            if p == cloud.preset { cloudIndex = i }
        }
        cloudPresetPopup.selectItem(at: cloudIndex)
        if cloudBaseURLField.currentEditor() == nil { cloudBaseURLField.stringValue = cloud.baseURL }
        if cloudModelField.currentEditor() == nil { cloudModelField.stringValue = cloud.model }
        // Key 字段永不回填，只刷新"已保存/未保存"状态
        refreshCloudKeyState()
    }

    @objc private func onAIChanged() {
        let app = AppState.shared
        syncFromConfig()
        if app.isAIReviewing {
            resultLabel.stringValue = "AI 处理中…"
            resultLabel.textColor = Theme.accent
        } else if let err = app.aiLastError {
            resultLabel.stringValue = err
            resultLabel.textColor = Theme.distribute
        } else if !app.aiStatus.isEmpty {
            resultLabel.stringValue = app.aiStatus
            resultLabel.textColor = Theme.buy
        }
        enableSwitch.state = app.aiConfig.enabled ? .on : .off
    }

    private func addField(_ label: String, _ field: NSTextField) {
        let l = L.label(label, size: 8.5, color: Theme.textDim)
        l.widthAnchor.constraint(equalToConstant: 62).isActive = true
        let row = L.hstack([l, field], spacing: 5)
        addBody(row)
        row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    }

    @objc private func save() {
        var cfg = AppState.shared.aiConfig
        cfg.enabled = enableSwitch.state == .on
        cfg.baseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.apiKey = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(maxCandidates.stringValue) { cfg.maxCandidatesPerScan = max(1, min(10, n)) }
        AppState.shared.saveAIConfig(cfg)
    }

    @objc private func testConnection() {
        save()
        let cfg = AppState.shared.aiConfig
        if !cfg.isUsable {
            resultLabel.stringValue = cfg.apiKey.isEmpty ? "✗ 请先填写 API Key" : "✗ 请先启用开关"
            resultLabel.textColor = Theme.distribute
            return
        }
        resultLabel.stringValue = "测试中…"
        resultLabel.textColor = Theme.textDim
        Task { @MainActor in
            let r = await AIClient.shared.testConnection(config: cfg)
            switch r {
            case .success(let msg):
                let short = msg.count > 40 ? String(msg.prefix(40)) + "…" : msg
                self.resultLabel.stringValue = "✓ 连接正常（\(short)）"
                self.resultLabel.textColor = Theme.buy
            case .failure(let err):
                self.resultLabel.stringValue = "✗ " + (err.errorDescription ?? "失败")
                self.resultLabel.textColor = Theme.distribute
            }
        }
    }
}

// MARK: - 主窗口

final class MainWindow: NSWindowController {

    static let reloadChart = Notification.Name("QuantLens.reloadChart")
    static let focusSearch = Notification.Name("QuantLens.focusSearch")
    static let reloadPanels = Notification.Name("QuantLens.reloadPanels")

    private let sidebar = SidebarView()  // 会在构造期创建
    private let chart = ChartView()
    private let intradayChart = IntradayChartView()
    private let orderBookPanel = OrderBookPanel()
    private let tapePanel = TradeTapePanel()
    private let largeOrderPanel = LargeOrderMonitorPanel()
    /// 图表区容器：K 线 / 分时 二选一
    private var chartHost: NSView!
    private let header = QuoteHeaderView()
    private let toolbar = ToolbarRow()

    private let signalPanel = SignalOverviewPanel()
    private let levelsPanel = LevelsPanel()
    private let trendPanel = TrendPanel()
    private let flowPanel = FundFlowPanel()
    private let detailPanel = SignalDetailPanel()
    private let backtestPanel = BacktestPanel()
    private let scanPanel = ScanPanel()
    private let aiPanel = AISettingsPanel()
    /// 实时短线买点榜（右栏首位）
    private let buyPointBoardPanel = BuyPointBoardPanel()
    /// 底部竞价榜单
    private let auctionBoardPanel = AuctionBoardPanel()
    private let verdictPanel = VerdictPanel()
    private let strategyPanel = StrategyPanel()
    private let fundamentalPanel = FundamentalPanel()

    private let loadingOverlay = LoadingOverlay()
    private var bottomRow: NSStackView!
    private var bottomHeight: NSLayoutConstraint!
    private var bottomCollapsed = false

    convenience init() {
        // 自适应屏幕：不超过可用区域
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(1500, screen.width - 40)
        let h = min(940, screen.height - 40)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "QuantLens 量化看盘"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Theme.bg
        window.minSize = NSSize(width: 1120, height: 640)
        window.appearance = NSAppearance(named: .darkAqua)
        self.init(window: window)
        buildUI()
        observe()
        window.center()
    }

    private func buildUI() {
        guard let window else { return }
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.bg.cgColor

        // ===== 顶部条 =====
        let topBar = NSView()
        topBar.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = L.label("QuantLens", size: 11, weight: .semibold, color: Theme.textDim)
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = Theme.accent.cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let refreshButton = makeTextButton("⟳ 刷新", #selector(manualRefresh), color: Theme.textDim)
        let scanButton = makeTextButton("⚡ 开盘扫描", #selector(manualScan), color: Theme.accent)
        let analyzeButton = makeTextButton("🧠 AI 分析", #selector(manualAnalyze), color: Theme.risk)

        let topRow = L.hstack([dot, titleLabel, L.spacer(), analyzeButton, scanButton, refreshButton], spacing: 10)
        topBar.addSubview(topRow)
        NSLayoutConstraint.activate([
            topRow.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 14),
            topRow.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -14),
            topRow.centerYAnchor.constraint(equalTo: topBar.centerYAnchor)
        ])

        // ===== 侧边栏 =====
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        // ===== 行情头部 =====
        let headerBox = RoundedBox()
        headerBox.fillColor = Theme.panel
        headerBox.translatesAutoresizingMaskIntoConstraints = false
        headerBox.addSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.setWatchHandler { [weak self] in self?.toggleCurrentWatch() }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: headerBox.topAnchor),
            header.bottomAnchor.constraint(equalTo: headerBox.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: headerBox.trailingAnchor)
        ])

        // ===== 工具条 =====
        let toolbarBox = RoundedBox()
        toolbarBox.fillColor = Theme.panel
        toolbarBox.cornerRadius = 6
        toolbarBox.translatesAutoresizingMaskIntoConstraints = false
        toolbarBox.addSubview(toolbar)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: toolbarBox.topAnchor),
            toolbar.bottomAnchor.constraint(equalTo: toolbarBox.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: toolbarBox.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: toolbarBox.trailingAnchor)
        ])

        // ===== 图表 =====
        let chartBox = RoundedBox()
        chartBox.fillColor = Theme.bg
        chartBox.cornerRadius = 8
        chartBox.translatesAutoresizingMaskIntoConstraints = false

        // K 线 + 分时 叠在同一位置，用 isHidden 切换
        chartHost = NSView()
        chartHost.translatesAutoresizingMaskIntoConstraints = false
        chartBox.addSubview(chartHost)

        chart.translatesAutoresizingMaskIntoConstraints = false
        intradayChart.translatesAutoresizingMaskIntoConstraints = false
        chartHost.addSubview(chart)
        chartHost.addSubview(intradayChart)
        for v in [chart, intradayChart] {
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: chartHost.topAnchor),
                v.bottomAnchor.constraint(equalTo: chartHost.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: chartHost.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: chartHost.trailingAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            chartHost.topAnchor.constraint(equalTo: chartBox.topAnchor, constant: 6),
            chartHost.bottomAnchor.constraint(equalTo: chartBox.bottomAnchor, constant: -4),
            chartHost.leadingAnchor.constraint(equalTo: chartBox.leadingAnchor, constant: 6),
            chartHost.trailingAnchor.constraint(equalTo: chartBox.trailingAnchor, constant: -4)
        ])

        // ===== 右侧栏（滚动，内容不定高） =====
        let rightColumn = FlippedStackView()
        rightColumn.orientation = .vertical
        rightColumn.spacing = 7
        rightColumn.alignment = .leading
        rightColumn.distribution = .fill
        rightColumn.translatesAutoresizingMaskIntoConstraints = false
        for p in [buyPointBoardPanel, fundamentalPanel, strategyPanel, verdictPanel, orderBookPanel, tapePanel, largeOrderPanel, signalPanel, levelsPanel, trendPanel] {
            rightColumn.addArrangedSubview(p)
            p.translatesAutoresizingMaskIntoConstraints = false
            p.widthAnchor.constraint(equalTo: rightColumn.widthAnchor).isActive = true
        }
        let rightScroll = makeScrollable(rightColumn)

        // ===== 底部行 =====
        bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 7
        bottomRow.alignment = .top
        bottomRow.distribution = .fill
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        bottomRow.addArrangedSubview(detailPanel)
        bottomRow.addArrangedSubview(flowPanel)
        bottomRow.addArrangedSubview(backtestPanel)
        bottomRow.addArrangedSubview(auctionBoardPanel)
        for v in [detailPanel, flowPanel, backtestPanel, auctionBoardPanel] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        flowPanel.widthAnchor.constraint(equalToConstant: 236).isActive = true
        backtestPanel.widthAnchor.constraint(equalToConstant: 300).isActive = true
        auctionBoardPanel.widthAnchor.constraint(equalToConstant: 306).isActive = true

        root.addSubview(topBar)
        root.addSubview(sidebar)
        root.addSubview(headerBox)
        root.addSubview(toolbarBox)
        root.addSubview(chartBox)
        root.addSubview(rightScroll)
        root.addSubview(bottomRow)

        bottomHeight = bottomRow.heightAnchor.constraint(equalToConstant: 176)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 16),

            sidebar.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 4),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 208),

            headerBox.topAnchor.constraint(equalTo: sidebar.topAnchor),
            headerBox.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 8),
            headerBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            headerBox.heightAnchor.constraint(equalToConstant: 62),

            toolbarBox.topAnchor.constraint(equalTo: headerBox.bottomAnchor, constant: 5),
            toolbarBox.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor),
            toolbarBox.trailingAnchor.constraint(equalTo: headerBox.trailingAnchor),
            toolbarBox.heightAnchor.constraint(equalToConstant: 25),

            chartBox.topAnchor.constraint(equalTo: toolbarBox.bottomAnchor, constant: 5),
            chartBox.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor),
            chartBox.trailingAnchor.constraint(equalTo: rightScroll.leadingAnchor, constant: -7),
            chartBox.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -5),

            rightScroll.topAnchor.constraint(equalTo: chartBox.topAnchor),
            rightScroll.trailingAnchor.constraint(equalTo: headerBox.trailingAnchor),
            rightScroll.widthAnchor.constraint(equalToConstant: 330),
            rightScroll.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -5),

            bottomRow.leadingAnchor.constraint(equalTo: chartBox.leadingAnchor),
            bottomRow.trailingAnchor.constraint(equalTo: headerBox.trailingAnchor),
            bottomRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            bottomHeight
        ])

        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(loadingOverlay)
        NSLayoutConstraint.activate([
            loadingOverlay.centerXAnchor.constraint(equalTo: chartBox.centerXAnchor),
            loadingOverlay.centerYAnchor.constraint(equalTo: chartBox.centerYAnchor)
        ])

        window.contentView = root
        updateChartVisibility()
        refreshAll()
        installKeyMonitor()
    }

    /// ⌘S：导出当前窗口截图
    static func saveScreenshot(_ window: NSWindowController?) {
        guard let win = window?.window ?? NSApp.mainWindow ?? NSApp.windows.first,
              let view = win.contentView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let name = "QuantLens-\(df.string(from: Date())).png"
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let url = dir.appendingPathComponent(name)
        try? png.write(to: url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func makeTextButton(_ title: String, _ action: Selector, color: NSColor) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.setButtonType(.momentaryChange)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Fonts.ui(10, weight: .medium), .foregroundColor: color
        ])
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private var keyMonitor: Any?

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 有文本输入焦点的控件里不拦截（搜索框正在打字）
            if let responder = self?.window?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }
            let app = AppState.shared
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // 无修饰键的单键快捷键
            if flags.isEmpty {
                switch event.keyCode {
                case 125: app.stepWatchlist(1); return nil      // ↓
                case 126: app.stepWatchlist(-1); return nil     // ↑
                case 124: app.stepPeriod(1); return nil         // →
                case 123: app.stepPeriod(-1); return nil        // ←
                default: break
                }
                return event
            }

            // ⌘ 组合
            if flags.contains(.command) {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "f":
                    NotificationCenter.default.post(name: MainWindow.focusSearch, object: nil)
                    return nil
                case "d":
                    AppState.shared.addCurrentToWatchlist()
                    return nil
                case "n":
                    // ⌘N：聚焦搜索框输入新代码
                    NotificationCenter.default.post(name: MainWindow.focusSearch, object: nil)
                    return nil

                default: break
                }
            }
            return event
        }
    }

    private func observe() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(onData), name: AppState.didChangeData, object: nil)
        nc.addObserver(self, selector: #selector(onSelection), name: AppState.didChangeSelection, object: nil)
        nc.addObserver(self, selector: #selector(onStatus), name: AppState.didChangeStatus, object: nil)
        nc.addObserver(self, selector: #selector(onQuotes), name: AppState.didChangeQuotes, object: nil)
        nc.addObserver(self, selector: #selector(onReloadChart), name: MainWindow.reloadChart, object: nil)
        nc.addObserver(self, selector: #selector(onAISettings), name: AppState.didRequestAISettings, object: nil)
        nc.addObserver(self, selector: #selector(onWatchlist), name: AppState.didChangeWatchlist, object: nil)
        nc.addObserver(self, selector: #selector(onIntraday), name: AppState.didChangeIntraday, object: nil)
        nc.addObserver(self, selector: #selector(onLocalVerdict), name: AppState.didChangeLocalVerdict, object: nil)
        nc.addObserver(self, selector: #selector(onTrades), name: AppState.didChangeTrades, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func onData() {
        refreshHeader()
        refreshChart()
        refreshPanels()
        // 切标的后立即拉一次盘中数据
        Task { await AppState.shared.refreshIntraday() }
    }

    @objc private func onSelection() {
        refreshHeader()
        toolbar.updateStates()
        refreshChart()
        refreshPanels()
    }

    @objc private func onQuotes() { refreshHeader() }
    @objc private func onWatchlist() { refreshHeader() }

    @objc private func onIntraday() {
        let app = AppState.shared
        intradayChart.update(app.intraday)
        orderBookPanel.refresh(book: app.orderBook,
                               previousClose: app.intraday?.previousClose ?? app.data?.quote?.prevClose ?? 0)
        updateIntradayLevels()
        updateChartVisibility()
        syncSignals()
    }

    /// 分时图叠加支撑/压力虚线：日内证据与日线最近价位合并取最近一档。
    /// 必须校验日线分析属于当前分时标的，否则会把上一只的价位画到当前图上。
    private func updateIntradayLevels() {
        let app = AppState.shared
        guard let d = app.intraday,
              let analysis = app.analysis,
              app.data?.security.id == d.security.id else {
            intradayChart.updateLevels(support: nil, resistance: nil)
            return
        }
        let dailySupport = analysis.supports.max(by: { $0.price < $1.price })?.price
        let dailyResistance = analysis.resistances.min(by: { $0.price < $1.price })?.price
        let levels = IntradayLevels.compute(intraday: d,
                                            dailySupport: dailySupport,
                                            dailyResistance: dailyResistance)
        intradayChart.updateLevels(support: levels.support, resistance: levels.resistance)
    }

    @objc private func onLocalVerdict() {
        syncSignals()
        verdictPanel.refresh()
    }

    /// 把本地分析结果同步到分时图的买卖标注。
    /// 必须校验结论属于当前标的，否则切换股票时会残留上一只的标记。
    private func syncSignals() {
        let app = AppState.shared
        guard let v = app.localVerdict, app.localVerdictMatchesSelection else {
            intradayChart.updateSignals(buy: [], sell: [])
            return
        }
        intradayChart.updateSignals(buy: v.buyMarks, sell: v.sellMarks)
    }

    @objc private func onTrades() {
        tapePanel.refresh(trades: AppState.shared.trades)
    }
    @objc private func onStatus() { loadingOverlay.setVisible(AppState.shared.isLoading) }
    @objc private func onReloadChart() { refreshChart() }

    @objc private func onAISettings() {
        // 把 AI 面板滚到可见区域（简单做法：折叠底栏时展开）
        if bottomCollapsed { toggleBottom() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            bottomRow.animator().alphaValue = 1.0
        }
    }

    @objc private func manualRefresh() {
        Task { await AppState.shared.refreshAll() }
    }

    @objc private func manualScan() {
        AppState.shared.startScan(includeAI: false)
    }

    /// 一键智能分析：本地引擎立即研判走势并给出买卖点位
    @objc private func manualAnalyze() {
        Task { @MainActor in
            await AppState.shared.analyzeNow()
        }
    }

    @objc private func openAISettings() {
        onAISettings()
    }

    private func toggleBottom() {
        bottomCollapsed.toggle()
        bottomHeight.constant = bottomCollapsed ? 0 : 190
        bottomRow.isHidden = bottomCollapsed
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            self.window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - 刷新

    private func refreshAll() {
        refreshHeader()
        toolbar.updateStates()
        refreshChart()
        refreshPanels()
    }

    private func refreshHeader() {
        header.refresh()
    }

    /// 头部按钮：加入 / 移除自选
    private func toggleCurrentWatch() {
        let app = AppState.shared
        guard let cur = app.selected else { return }
        if app.isCurrentInWatchlist {
            app.remove(cur.id)
        } else {
            app.add(cur)
        }
    }

    /// 分时 / K线 切换
    private func updateChartVisibility() {
        let showIntraday = AppState.shared.showIntraday
        chart.isHidden = showIntraday
        intradayChart.isHidden = !showIntraday
    }

    private func refreshChart() {
        let app = AppState.shared
        guard let analysis = app.analysis else {
            chart.update(context: nil, markers: [], levels: [], intraday: app.period.isIntraday)
            return
        }
        chart.showMA = app.showMA
        chart.showBoll = app.showBoll
        chart.showLevels = app.showLevels
        chart.showMarkers = app.showMarkers
        chart.subIndicator = app.subIndicator
        chart.update(context: analysis.context,
                     markers: analysis.markers,
                     levels: analysis.context.levels,
                     intraday: app.period.isIntraday,
                     tradePoints: analysis.tradePoints,
                     fearHistory: analysis.fearHistory)
    }

    private func refreshPanels() {
        aiPanel.syncIfNeeded()
        signalPanel.refresh()
        levelsPanel.refresh()
        trendPanel.refresh()
        flowPanel.refresh()
        detailPanel.refresh()
        backtestPanel.refresh()
        scanPanel.refresh()
    }
}

// MARK: - 加载遮罩

final class LoadingOverlay: NSView {

    private let spinner = NSProgressIndicator()
    private let label = L.label("加载数据…", size: 10, color: Theme.textDim)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.withAlphaComponent(0.72).cgColor
        layer?.cornerRadius = 8

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let stack = L.vstack([spinner, label], spacing: 6)
        stack.alignment = .centerX
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22)
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func setVisible(_ visible: Bool) {
        if visible {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        isHidden = !visible
    }
}