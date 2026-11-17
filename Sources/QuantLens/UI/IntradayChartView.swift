import AppKit

// MARK: - 分时图视图

/// 分时图（Time & Sales chart）。
///
/// 与 K 线图的关键差异：
/// - 时间轴固定 9:30~15:00（240 分钟），未到的时间留空
/// - 价格轴以昨收为中轴上下对称，涨跌幅刻度
/// - 两条线：白色/蓝色价格线 + 黄色均价线
/// - 下方成交量柱（按涨跌上色）
/// - 支撑/压力：最近一档支撑与压力画虚线（日内证据与日线价位合并取最近，
///   由 MainWindow 通过 updateLevels 传入；无数据时不画）
final class IntradayChartView: NSView {

    private var data: IntradayData?
    private var crosshairIndex: Int?
    private var crosshairPoint: CGPoint?

    /// 买点/卖点标注（由 AI 分析结果驱动）
    private var buyMarks: [LocalAnalyst.Mark] = []
    private var sellMarks: [LocalAnalyst.Mark] = []
    /// 是否显示买卖标注
    var showSignals = true {
        didSet { needsDisplay = true }
    }

    /// 最近一档支撑 / 压力（日内证据与日线价位合并，见 IntradayLevels）
    private var supportLevel: Double?
    private var resistanceLevel: Double?

    // 布局
    private let axisWidth: CGFloat = 58
    private let bottomAxisHeight: CGFloat = 16
    private let priceRatio: CGFloat = 0.72
    /// 上午 9:30-11:30 (120min) + 下午 13:00-15:00 (120min)
    private let totalMinutes = 240

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var isFlipped: Bool { true }

    func update(_ d: IntradayData?) {
        data = d
        crosshairIndex = nil
        needsDisplay = true
    }

    /// 更新买卖点标注。传 nil 清除。
    func updateSignals(buy: [LocalAnalyst.Mark], sell: [LocalAnalyst.Mark]) {
        buyMarks = buy
        sellMarks = sell
        needsDisplay = true
    }

    /// 更新支撑/压力虚线。传 nil 清除对应价位。
    func updateLevels(support: Double?, resistance: Double?) {
        supportLevel = support
        resistanceLevel = resistance
        needsDisplay = true
    }

    // MARK: 几何

    private var plotWidth: CGFloat { bounds.width - axisWidth }
    private var priceHeight: CGFloat { (bounds.height - bottomAxisHeight) * priceRatio }
    private var volTop: CGFloat { priceHeight + 4 }
    private var volHeight: CGFloat { bounds.height - bottomAxisHeight - priceHeight - 6 }

    /// 分钟序号 → x（跳过 11:30~13:00 午休）
    private func xFor(minuteIndex m: Int) -> CGFloat {
        let step = plotWidth / CGFloat(totalMinutes)
        return CGFloat(m) * step + step / 2
    }

    /// 时间 → 分钟序号（0~239）
    private func minuteIndex(of date: Date) -> Int? {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: date)
        guard let h = c.hour, let mm = c.minute else { return nil }
        let minutes = h * 60 + mm
        if minutes >= 9 * 60 + 30 && minutes <= 11 * 60 + 30 {
            return minutes - (9 * 60 + 30)
        }
        if minutes >= 13 * 60 && minutes <= 15 * 60 {
            return 120 + (minutes - 13 * 60)
        }
        return nil
    }

    // MARK: 价格范围

    private func priceRange() -> (lo: Double, hi: Double, prevClose: Double) {
        guard let d = data, d.previousClose > 0 else { return (0, 1, 0) }
        let prev = d.previousClose
        // 以昨收为中轴，取当日最大偏离，至少 ±1% 保证小波动也有可读性
        var maxDev = 0.01
        for p in d.points {
            maxDev = max(maxDev, abs(p.price / prev - 1))
            maxDev = max(maxDev, abs(p.avgPrice / prev - 1))
        }
        maxDev *= 1.15
        return (prev * (1 - maxDev), prev * (1 + maxDev), prev)
    }

    private func yFor(price: Double, range: (lo: Double, hi: Double, prevClose: Double)) -> CGFloat {
        let span = range.hi - range.lo
        guard span > 0 else { return priceHeight / 2 }
        return priceHeight - CGFloat((price - range.lo) / span) * priceHeight
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        g.fillRect(bounds, Theme.bg)

        guard let d = data, !d.points.isEmpty, d.previousClose > 0 else {
            g.drawText("分时数据加载中…", at: CGPoint(x: bounds.midX, y: bounds.midY),
                       font: Fonts.ui(11), color: Theme.textFaint, align: .center)
            return
        }

        let range = priceRange()
        drawGrid(g, range: range)
        drawPriceArea(g, d: d, range: range)
        drawAvgLine(g, d: d, range: range)
        drawSupportResistance(g, range: range)
        drawVolume(g, d: d)
        drawTimeAxis(g)
        if showSignals {
            drawSignals(g, d: d, range: range)
        }
        drawLegend(g, d: d, range: range)
        drawCrosshair(g, d: d, range: range)
    }

    private func drawGrid(_ g: CGContext, range: (lo: Double, hi: Double, prevClose: Double)) {
        let prev = range.prevClose

        // 水平网格：昨收 + 上下各 2 档
        let levels = 4
        for i in -levels...levels {
            let pct = Double(i) * (range.hi - prev) / prev / Double(levels) * 100
            let price = prev * (1 + pct / 100)
            let y = yFor(price: price, range: range)
            let isCenter = (i == 0)
            g.strokeLine(from: CGPoint(x: 0, y: y), to: CGPoint(x: plotWidth, y: y),
                         color: isCenter ? Theme.textFaint.alpha(0.55) : Theme.grid.alpha(0.5),
                         width: isCenter ? 0.8 : 0.5,
                         dash: isCenter ? [3, 3] : [])

            // 右轴：价格
            let priceColor = pct > 0.001 ? Theme.up : (pct < -0.001 ? Theme.down : Theme.textDim)
            g.drawText(Fmt.price(price, decimals: price >= 100 ? 2 : 3),
                       at: CGPoint(x: plotWidth + 5, y: y - 5.5),
                       font: Fonts.mono(8), color: priceColor)
            // 右轴：涨跌幅
            g.drawText(Fmt.pct(pct, decimals: 2),
                       at: CGPoint(x: plotWidth + axisWidth - 3, y: y - 5.5),
                       font: Fonts.mono(7.5), color: priceColor.alpha(0.75), align: .right)
        }

        // 垂直网格：每 30 分钟
        for m in stride(from: 0, through: totalMinutes, by: 30) {
            let x = xFor(minuteIndex: m)
            g.strokeLine(from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: bounds.height - bottomAxisHeight),
                         color: Theme.grid.alpha(0.4), width: 0.5)
        }

        // 午休分隔（更醒目的竖线）
        let noonX = xFor(minuteIndex: 120)
        g.strokeLine(from: CGPoint(x: noonX, y: 0), to: CGPoint(x: noonX, y: bounds.height - bottomAxisHeight),
                     color: Theme.border.alpha(0.9), width: 0.8)
    }

    private func drawPriceArea(_ g: CGContext, d: IntradayData, range: (lo: Double, hi: Double, prevClose: Double)) {
        let prev = d.previousClose
        var points: [(x: CGFloat, y: CGFloat, price: Double)] = []
        for p in d.points {
            guard let mi = minuteIndex(of: p.time) else { continue }
            points.append((xFor(minuteIndex: mi), yFor(price: p.price, range: range), p.price))
        }
        guard points.count > 1 else { return }

        // 渐变填充（价线到昨收线之间）
        let prevY = yFor(price: prev, range: range)
        let lastPrice = points.last!.price
        let fillColor = (lastPrice >= prev ? Theme.up : Theme.down)

        g.saveGState()
        let clipPath = CGMutablePath()
        clipPath.move(to: CGPoint(x: points[0].x, y: prevY))
        for p in points { clipPath.addLine(to: CGPoint(x: p.x, y: p.y)) }
        clipPath.addLine(to: CGPoint(x: points.last!.x, y: prevY))
        clipPath.closeSubpath()
        g.addPath(clipPath)
        g.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [fillColor.alpha(0.24).cgColor, fillColor.alpha(0.02).cgColor] as CFArray,
                                     locations: [0, 1]) {
            g.drawLinearGradient(gradient,
                                 start: CGPoint(x: 0, y: min(prevY, points.map(\.y).min() ?? prevY)),
                                 end: CGPoint(x: 0, y: max(prevY, points.map(\.y).max() ?? prevY)),
                                 options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        g.restoreGState()

        // 价线
        g.setStrokeColor(fillColor.cgColor)
        g.setLineWidth(1.3)
        g.beginPath()
        g.move(to: CGPoint(x: points[0].x, y: points[0].y))
        for p in points.dropFirst() { g.addLine(to: CGPoint(x: p.x, y: p.y)) }
        g.strokePath()

        // 最新价点
        if let last = points.last {
            g.setFillColor(fillColor.cgColor)
            g.fillEllipse(in: CGRect(x: last.x - 2.2, y: last.y - 2.2, width: 4.4, height: 4.4))
            // 价格标签
            let text = Fmt.price(last.price, decimals: last.price >= 100 ? 2 : 3)
            g.fillRoundedRect(CGRect(x: plotWidth + 1, y: last.y - 7, width: axisWidth - 3, height: 14),
                              radius: 2.5, color: fillColor.alpha(0.9))
            g.drawText(text, at: CGPoint(x: plotWidth + axisWidth / 2, y: last.y - 5.5),
                       font: Fonts.mono(8.5, weight: .semibold), color: .white, align: .center)
        }
    }

    private func drawAvgLine(_ g: CGContext, d: IntradayData, range: (lo: Double, hi: Double, prevClose: Double)) {
        var started = false
        g.setStrokeColor(Theme.ma5.alpha(0.92).cgColor)
        g.setLineWidth(1.0)
        g.beginPath()
        for p in d.points {
            guard p.avgPrice > 0, let mi = minuteIndex(of: p.time) else { continue }
            let pt = CGPoint(x: xFor(minuteIndex: mi), y: yFor(price: p.avgPrice, range: range))
            if !started { g.move(to: pt); started = true } else { g.addLine(to: pt) }
        }
        g.strokePath()
    }

    private func drawVolume(_ g: CGContext, d: IntradayData) {
        guard volHeight > 4 else { return }
        let maxVol = d.points.map(\.volume).max() ?? 1
        guard maxVol > 0 else { return }

        let prev = d.points.first?.price ?? 0
        _ = prev
        var lastPrice = d.previousClose

        for p in d.points {
            guard let mi = minuteIndex(of: p.time) else { continue }
            let x = xFor(minuteIndex: mi)
            let w = max(1.0, plotWidth / CGFloat(totalMinutes) * 0.68)
            let h = CGFloat(p.volume / maxVol) * volHeight
            let up = p.price >= lastPrice
            lastPrice = p.price
            g.fillRect(CGRect(x: x - w / 2, y: volTop + volHeight - h, width: w, height: max(0.5, h)),
                       (up ? Theme.up : Theme.down).alpha(0.58))
        }
    }

    private func drawTimeAxis(_ g: CGContext) {
        let labels: [(Int, String)] = [
            (0, "09:30"), (60, "10:30"), (120, "11:30/13:00"),
            (180, "14:00"), (240, "15:00")
        ]
        let y = bounds.height - bottomAxisHeight + 3
        for (m, text) in labels {
            let x = xFor(minuteIndex: m)
            g.drawText(text, at: CGPoint(x: x, y: y), font: Fonts.mono(7.5),
                       color: Theme.textFaint, align: .center)
        }
        g.strokeLine(from: CGPoint(x: plotWidth, y: 0), to: CGPoint(x: plotWidth, y: bounds.height),
                     color: Theme.border.alpha(0.5), width: 0.5)
    }

    /// 绘制最近一档支撑/压力虚线。颜色与 K 线图一致：支撑绿、压力粉。
    /// 价位超出当前价格范围时不画，避免误导。
    private func drawSupportResistance(_ g: CGContext, range: (lo: Double, hi: Double, prevClose: Double)) {
        var levels: [(price: Double, kind: LevelKind)] = []
        if let s = supportLevel { levels.append((s, .support)) }
        if let r = resistanceLevel { levels.append((r, .resistance)) }
        for (price, kind) in levels {
            guard price >= range.lo, price <= range.hi else { continue }
            let y = yFor(price: price, range: range)
            let color = kind == .support ? Theme.buy : Theme.distribute
            g.strokeLine(from: CGPoint(x: 0, y: y), to: CGPoint(x: plotWidth, y: y),
                         color: color.alpha(0.55), width: 0.8, dash: [3.5, 3])

            let text = "\(kind.label) \(Fmt.price(price, decimals: price >= 100 ? 2 : 3))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Fonts.mono(8, weight: .medium),
                .foregroundColor: color.alpha(0.95)
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            let labelY = max(1, min(priceHeight - 12, y - 6))
            g.fillRoundedRect(CGRect(x: 2, y: labelY - 0.5, width: size.width + 7, height: size.height + 1),
                              radius: 2.5, color: color.alpha(0.16))
            g.drawText(text, at: CGPoint(x: 5, y: labelY),
                       font: Fonts.mono(8, weight: .medium), color: color.alpha(0.95))
        }
    }

    /// 绘制买点/卖点标注。
    /// 买：红色向上三角 + 「买」字，标在分时线下方；
    /// 卖：绿色向下三角 + 「卖」字，标在分时线上方。
    private func drawSignals(_ g: CGContext, d: IntradayData, range: (lo: Double, hi: Double, prevClose: Double)) {
        guard !buyMarks.isEmpty || !sellMarks.isEmpty else { return }

        // 价格 → 分时序号需要反查（marks 里已有 index，直接用）
        for m in buyMarks {
            drawSingleMark(g, mark: m, priceRange: range, isBuy: true, total: d.points.count)
        }
        for m in sellMarks {
            drawSingleMark(g, mark: m, priceRange: range, isBuy: false, total: d.points.count)
        }
    }

    private func drawSingleMark(_ g: CGContext, mark: LocalAnalyst.Mark,
                                priceRange: (lo: Double, hi: Double, prevClose: Double),
                                isBuy: Bool, total: Int) {
        // 把 points 索引换算成分钟序号
        guard let d = data, mark.index >= 0, mark.index < d.points.count else { return }
        guard let mi = minuteIndex(of: d.points[mark.index].time) else { return }

        let x = xFor(minuteIndex: mi)
        let y = yFor(price: mark.price, range: priceRange)
        let color = isBuy ? Theme.up : Theme.down

        // 三角标记
        let size: CGFloat = 5.5
        let offset: CGFloat = isBuy ? 11 : -11
        let cy = y + offset

        g.setFillColor(color.cgColor)
        if isBuy {
            // 向上三角（买）
            g.move(to: CGPoint(x: x, y: cy - size))
            g.addLine(to: CGPoint(x: x - size * 0.85, y: cy + size * 0.5))
            g.addLine(to: CGPoint(x: x + size * 0.85, y: cy + size * 0.5))
        } else {
            // 向下三角（卖）
            g.move(to: CGPoint(x: x, y: cy + size))
            g.addLine(to: CGPoint(x: x - size * 0.85, y: cy - size * 0.5))
            g.addLine(to: CGPoint(x: x + size * 0.85, y: cy - size * 0.5))
        }
        g.closePath()
        g.fillPath()

        // 「买」「卖」文字
        let label = isBuy ? "买" : "卖"
        let textY = isBuy ? cy + size * 0.5 + 1 : cy - size * 0.5 - 10
        g.drawText(label,
                   at: CGPoint(x: x - 4.5, y: textY),
                   font: Fonts.ui(8, weight: .bold),
                   color: color)

        // 虚线延伸到横轴，提示这是关键价位
        g.strokeLine(from: CGPoint(x: x, y: y),
                     to: CGPoint(x: x, y: bounds.height - bottomAxisHeight),
                     color: color.alpha(0.35), width: 0.5, dash: [2, 3])
    }

    private func drawLegend(_ g: CGContext, d: IntradayData, range: (lo: Double, hi: Double, prevClose: Double)) {
        var items: [(String, NSColor)] = []
        items.append(("昨收 \(Fmt.price(d.previousClose))", Theme.textDim))
        if let avg = d.points.last?.avgPrice {
            items.append(("均价 \(Fmt.price(avg))", Theme.ma5))
        }
        let chg = d.lastChangePct
        items.append((Fmt.pct(chg), Theme.color(change: chg)))

        var x: CGFloat = 6
        for (text, color) in items {
            let attrs: [NSAttributedString.Key: Any] = [.font: Fonts.mono(8), .foregroundColor: color]
            let w = (text as NSString).size(withAttributes: attrs).width
            g.drawText(text, at: CGPoint(x: x, y: 3), font: Fonts.mono(8), color: color)
            x += w + 10
        }
    }

    // MARK: 十字光标

    private func drawCrosshair(_ g: CGContext, d: IntradayData, range: (lo: Double, hi: Double, prevClose: Double)) {
        guard let idx = crosshairIndex, idx >= 0, idx < d.points.count else { return }
        let p = d.points[idx]
        guard let mi = minuteIndex(of: p.time) else { return }
        let x = xFor(minuteIndex: mi)

        g.strokeLine(from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: bounds.height - bottomAxisHeight),
                     color: Theme.textDim.alpha(0.5), width: 0.6, dash: [3, 3])

        if let cp = crosshairPoint, cp.y < priceHeight {
            let price = range.lo + (range.hi - range.lo) * Double((priceHeight - cp.y) / priceHeight)
            g.strokeLine(from: CGPoint(x: 0, y: cp.y), to: CGPoint(x: plotWidth, y: cp.y),
                         color: Theme.textDim.alpha(0.5), width: 0.6, dash: [3, 3])
            g.fillRoundedRect(CGRect(x: plotWidth + 1, y: cp.y - 7, width: axisWidth - 3, height: 14),
                              radius: 2.5, color: Theme.panel3)
            g.drawText(Fmt.price(price, decimals: price >= 100 ? 2 : 3),
                       at: CGPoint(x: plotWidth + axisWidth / 2, y: cp.y - 5.5),
                       font: Fonts.mono(8.5), color: Theme.text, align: .center)
        }

        // 时间刻度
        g.fillRoundedRect(CGRect(x: x - 22, y: bounds.height - bottomAxisHeight + 1, width: 44, height: 13),
                          radius: 2, color: Theme.panel3)
        g.drawText(Fmt.intradayFormatter.string(from: p.time),
                   at: CGPoint(x: x, y: bounds.height - bottomAxisHeight + 2.5),
                   font: Fonts.mono(8), color: Theme.text, align: .center)

        // 信息浮层
        let chg = (p.price / d.previousClose - 1) * 100
        let lines: [(String, NSColor)] = [
            (Fmt.intradayFormatter.string(from: p.time), Theme.text),
            ("价 \(Fmt.price(p.price))", Theme.color(change: chg)),
            ("均 \(Fmt.price(p.avgPrice))", Theme.ma5),
            (Fmt.pct(chg), Theme.color(change: chg)),
            ("量 \(Fmt.price(p.volume, decimals: 0))手", Theme.textDim)
        ]
        var maxW: CGFloat = 0
        for (t, _) in lines {
            let attrs: [NSAttributedString.Key: Any] = [.font: Fonts.mono(8.5), .foregroundColor: Theme.text]
            maxW = max(maxW, (t as NSString).size(withAttributes: attrs).width)
        }
        let boxW = maxW + 12
        let boxH = CGFloat(lines.count) * 12 + 8
        var bx = x + 10
        if bx + boxW > plotWidth { bx = x - boxW - 10 }
        g.fillRoundedRect(CGRect(x: bx, y: 5, width: boxW, height: boxH), radius: 4, color: Theme.bg.alpha(0.94))
        g.strokeRoundedRect(CGRect(x: bx, y: 5, width: boxW, height: boxH), radius: 4,
                            color: Theme.border, width: 0.6)
        var ty: CGFloat = 9
        for (t, c) in lines {
            g.drawText(t, at: CGPoint(x: bx + 6, y: ty), font: Fonts.mono(8.5), color: c)
            ty += 12
        }
    }

    // MARK: 交互

    override func mouseMoved(with event: NSEvent) {
        guard let d = data, !d.points.isEmpty else { return }
        let p = convert(event.locationInWindow, from: nil)
        crosshairPoint = p
        let step = plotWidth / CGFloat(totalMinutes)
        guard step > 0 else { return }
        let mi = Int(p.x / step)
        guard mi >= 0, mi < totalMinutes else {
            crosshairIndex = nil; needsDisplay = true; return
        }
        // 找该分钟的最近点
        if let idx = d.points.firstIndex(where: { minuteIndex(of: $0.time) == mi }) {
            crosshairIndex = idx
        } else if let idx = d.points.lastIndex(where: { (minuteIndex(of: $0.time) ?? -1) <= mi }) {
            crosshairIndex = idx
        } else {
            crosshairIndex = nil
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        crosshairIndex = nil
        crosshairPoint = nil
        needsDisplay = true
    }
}
