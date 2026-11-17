import AppKit
import Foundation

// MARK: - K线图表视图（Core Graphics 自绘）

/// 单视图完成主图（K线+均线+支撑压力+信号标记）与副图（量/MACD/KDJ/RSI），
/// 带十字光标、滚轮缩放、拖拽平移。全部用 Core Graphics 直绘，无图层开销。
final class ChartView: NSView {

    // 数据
    private var ctx: MarketContext?
    private var markers: [TradingSignal] = []
    private var levels: [PriceLevel] = []
    private var tradePoints: [TradePointSignal] = []
    private var fearHistory: [FearSignal] = []
    private var intraday = true

    // 视图状态
    private var visibleBars: Int = 120
    private var scrollOffset: Int = 0
    private var crosshairIndex: Int? = nil
    private var crosshairPoint: CGPoint? = nil
    private var isDragging = false
    private var dragStartOffset: Int = 0
    private var dragStartPoint: CGPoint = .zero

    // 选项
    var showMA = true { didSet { needsDisplay = true } }
    var showBoll = false { didSet { needsDisplay = true } }
    var showLevels = true { didSet { needsDisplay = true } }
    var showMarkers = true { didSet { needsDisplay = true } }
    var subIndicator: SubIndicator = .volume { didSet { needsDisplay = true } }

    // 布局常量
    private let axisWidth: CGFloat = 62
    /// 左侧价位标签栏宽度（K线从这条线右侧开始画，避免标签压住K线）
    private let labelGutter: CGFloat = 88
    private let mainRatio: CGFloat = 0.75
    private let bottomAxisHeight: CGFloat = 16
    private let topInset: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor
        setupTracking()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func setupTracking() {
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    // MARK: - 数据注入

    func update(context: MarketContext?, markers: [TradingSignal], levels: [PriceLevel], intraday: Bool,
                tradePoints: [TradePointSignal] = [], fearHistory: [FearSignal] = []) {
        self.ctx = context
        self.markers = markers
        self.levels = levels
        self.tradePoints = tradePoints
        self.fearHistory = fearHistory
        self.intraday = intraday
        if let c = context {
            visibleBars = min(visibleBars, max(30, c.count))
            scrollOffset = min(scrollOffset, max(0, c.count - visibleBars))
        }
        needsDisplay = true
    }

    // MARK: - 几何

    private var total: Int { ctx?.count ?? 0 }

    private var effectiveOffset: Int {
        max(0, min(scrollOffset, max(0, total - visibleBars)))
    }

    private var barRange: Range<Int> {
        guard total > 0 else { return 0..<0 }
        let end = total - effectiveOffset
        let start = max(0, end - visibleBars)
        return start..<max(start + 1, end)
    }

    private var plotWidth: CGFloat { bounds.width - axisWidth }
    private var mainHeight: CGFloat { (bounds.height - bottomAxisHeight) * mainRatio }
    private var subTop: CGFloat { mainHeight + 4 }
    private var subHeight: CGFloat { bounds.height - bottomAxisHeight - mainHeight - 8 }

    /// K线绘制区（标签栏右侧到价格轴之间）
    private var drawLeft: CGFloat { labelGutter }
    private var drawWidth: CGFloat { max(1, plotWidth - labelGutter) }

    private func barWidth() -> CGFloat {
        let n = CGFloat(max(1, barRange.count)) + 4
        return drawWidth / n
    }

    private func xFor(localIndex: Int) -> CGFloat {
        let bw = barWidth()
        return drawLeft + bw / 2 + CGFloat(localIndex) * bw
    }

    /// 把 X 坐标反解成 bar 序号（十字光标用）
    private func localIndex(forX x: CGFloat) -> Int {
        let bw = barWidth()
        guard bw > 0 else { return 0 }
        return Int((x - drawLeft) / bw)
    }

    // MARK: - 价格范围

    private func priceRange() -> (lo: Double, hi: Double) {
        guard let ctx, !barRange.isEmpty else { return (0, 1) }
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for i in barRange {
            let c = ctx.candles[i]
            lo = min(lo, c.low)
            hi = max(hi, c.high)
            if showMA {
                for arr in [ctx.ma5, ctx.ma10, ctx.ma20, ctx.ma60] {
                    if let v = arr.value(i) { lo = min(lo, v); hi = max(hi, v) }
                }
            }
            if showBoll {
                if let u = ctx.boll.upper.value(i) { hi = max(hi, u) }
                if let l = ctx.boll.lower.value(i) { lo = min(lo, l) }
            }
        }
        if !lo.isFinite || !hi.isFinite || lo >= hi {
            return (0, 1)
        }
        let pad = (hi - lo) * 0.07
        return (lo - pad, hi + pad)
    }

    private func yFor(price: Double, range: (lo: Double, hi: Double)) -> CGFloat {
        let span = range.hi - range.lo
        guard span > 0 else { return mainHeight / 2 }
        let t = (price - range.lo) / span
        return mainHeight - CGFloat(t) * mainHeight
    }

    // MARK: - 绘制入口

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        context.fillRect(bounds, Theme.bg)

        guard let ctx, !barRange.isEmpty else {
            context.drawText("加载中…", at: CGPoint(x: bounds.midX, y: bounds.midY),
                             font: Fonts.ui(12), color: Theme.textDim, align: .center)
            return
        }

        let pr = priceRange()
        drawMainPanel(context, ctx: ctx, range: pr)
        drawSubPanel(context, ctx: ctx)
        drawSeparator(context)
        drawCrosshair(context, ctx: ctx, range: pr)
    }

    // MARK: - 主图

    private func drawMainPanel(_ g: CGContext, ctx: MarketContext, range pr: (lo: Double, hi: Double)) {
        let bw = barWidth()
        let cw = max(1.0, bw * 0.70)

        // 网格 + 价格轴
        let gridLines = 5
        for i in 0...gridLines {
            let t = CGFloat(i) / CGFloat(gridLines)
            let y = mainHeight * t
            g.strokeLine(from: CGPoint(x: labelGutter, y: y), to: CGPoint(x: plotWidth, y: y),
                         color: Theme.grid.alpha(0.55), width: 0.5)
            let price = pr.hi - (pr.hi - pr.lo) * Double(t)
            let label = Fmt.price(price, decimals: priceDecimals(price))
            g.drawText(label, at: CGPoint(x: plotWidth + 6, y: y - 5.5),
                       font: Fonts.mono(8.5), color: Theme.textFaint)
        }

        // 支撑压力
        if showLevels {
            // 先算标签位置，做垂直避让（同一高度不叠字）
            var labelYs: [CGFloat] = []
            let sorted = levels.sorted { $0.price > $1.price }
            for level in sorted {
                guard level.price >= pr.lo, level.price <= pr.hi else { continue }
                let y = yFor(price: level.price, range: pr)
                let color = level.kind == .support ? Theme.buy : Theme.distribute
                let alpha = 0.16 + min(0.40, level.score / 100 * 0.40)
                // 虚线朝左延伸，只延到标签右侧
                g.strokeLine(from: CGPoint(x: labelGutter - 4, y: y), to: CGPoint(x: plotWidth, y: y),
                             color: color.alpha(alpha),
                             width: level.score >= 60 ? 1.1 : 0.7,
                             dash: [3.5, 3])
                // 标签栏右缘的小圆点
                g.fillRoundedRect(CGRect(x: labelGutter - 6, y: y - 1.6, width: 3.2, height: 3.2),
                                  radius: 1.6, color: color.alpha(0.95))

                // 标签垂直避让
                var labelY = max(2, min(mainHeight - 13, y - 6))
                for prev in labelYs.sorted() where abs(prev - labelY) < 11.5 {
                    labelY += (labelY < y ? -11.5 : 11.5)
                }
                labelY = max(1, min(mainHeight - 12, labelY))
                labelYs.append(labelY)

                let text = "\(level.kind.label) \(Fmt.price(level.price, decimals: priceDecimals(level.price)))"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: Fonts.mono(8, weight: .medium),
                    .foregroundColor: color.alpha(0.95)
                ]
                let size = (text as NSString).size(withAttributes: attrs)
                g.fillRoundedRect(CGRect(x: 2, y: labelY - 0.5, width: size.width + 7, height: size.height + 1),
                                  radius: 2.5, color: color.alpha(0.16))
                g.drawText(text, at: CGPoint(x: 5, y: labelY),
                           font: Fonts.mono(8, weight: .medium), color: color.alpha(0.95))

                // 价格轴侧小三角
                g.setFillColor(color.alpha(0.8).cgColor)
                g.beginPath()
                g.move(to: CGPoint(x: plotWidth + 1, y: y))
                g.addLine(to: CGPoint(x: plotWidth + 5, y: y - 3))
                g.addLine(to: CGPoint(x: plotWidth + 5, y: y + 3))
                g.closePath()
                g.fillPath()

                // 价格轴侧只画一个小三角指示，不写数字，避免与刻度重叠
                g.setFillColor(color.alpha(0.85).cgColor)
                g.beginPath()
                g.move(to: CGPoint(x: plotWidth + 1, y: y))
                g.addLine(to: CGPoint(x: plotWidth + 5, y: y - 3))
                g.addLine(to: CGPoint(x: plotWidth + 5, y: y + 3))
                g.closePath()
                g.fillPath()
            }
        }

        // K线
        var local = 0
        for i in barRange {
            let c = ctx.candles[i]
            let x = xFor(localIndex: local)
            local += 1
            let color = c.isUp ? Theme.up : Theme.down
            let yHigh = yFor(price: c.high, range: pr)
            let yLow = yFor(price: c.low, range: pr)
            let yOpen = yFor(price: c.open, range: pr)
            let yClose = yFor(price: c.close, range: pr)

            // 影线
            g.strokeLine(from: CGPoint(x: x, y: yHigh), to: CGPoint(x: x, y: yLow),
                         color: color.alpha(0.92), width: max(0.7, cw * 0.10))

            // 实体
            let top = min(yOpen, yClose)
            var h = abs(yClose - yOpen)
            if h < 0.9 { h = 0.9 }
            let rect = CGRect(x: x - cw / 2, y: top, width: cw, height: h)
            g.fillRect(rect, color)
        }

        // 布林带
        if showBoll {
            drawSeries(g, values: ctx.boll.upper, pr: pr, color: Theme.accent.alpha(0.40), width: 0.8)
            drawSeries(g, values: ctx.boll.lower, pr: pr, color: Theme.accent.alpha(0.40), width: 0.8)
            drawSeries(g, values: ctx.boll.mid, pr: pr, color: Theme.accent.alpha(0.28), width: 0.7, dash: [3, 3])
        }

        // 均线
        if showMA {
            drawSeries(g, values: ctx.ma5, pr: pr, color: Theme.ma5.alpha(0.95), width: 1.0)
            drawSeries(g, values: ctx.ma10, pr: pr, color: Theme.ma10.alpha(0.95), width: 1.0)
            drawSeries(g, values: ctx.ma20, pr: pr, color: Theme.ma20, width: 1.15)
            drawSeries(g, values: ctx.ma60, pr: pr, color: Theme.ma60.alpha(0.95), width: 1.0)
        }

        // 信号标记：旧四类评分标记 + 新买卖点 + 恐惧/贪婪历史
        if showMarkers {
            drawMarkers(g, ctx: ctx, pr: pr)
            drawTradePoints(g, ctx: ctx, pr: pr)
            drawFearHistory(g, ctx: ctx, pr: pr)
        }

        // 最新价
        if let last = ctx.candles.last {
            let y = yFor(price: last.close, range: pr)
            let color = last.close >= last.open ? Theme.up : Theme.down
            g.strokeLine(from: CGPoint(x: labelGutter, y: y), to: CGPoint(x: plotWidth, y: y),
                         color: color.alpha(0.35), width: 0.7, dash: [2, 2])
            let text = Fmt.price(last.close, decimals: priceDecimals(last.close))
            g.fillRoundedRect(CGRect(x: plotWidth + 1, y: y - 7.5, width: axisWidth - 3, height: 15),
                              radius: 2.5, color: color.alpha(0.90))
            g.drawText(text, at: CGPoint(x: plotWidth + axisWidth / 2, y: y - 6),
                       font: Fonts.mono(9, weight: .semibold), color: .white, align: .center)
        }

        // 图例
        if showMA {
            var lx: CGFloat = 6
            let ly: CGFloat = mainHeight - 13
            for (label, color) in [("MA5", Theme.ma5), ("MA10", Theme.ma10), ("MA20", Theme.ma20), ("MA60", Theme.ma60)] {
                let attrs: [NSAttributedString.Key: Any] = [.font: Fonts.mono(8), .foregroundColor: color.alpha(0.9)]
                let w = (label as NSString).size(withAttributes: attrs).width
                g.drawText(label, at: CGPoint(x: lx, y: ly), font: Fonts.mono(8), color: color.alpha(0.9))
                lx += w + 8
            }
        }
    }

    private func drawSeries(_ g: CGContext, values: [Double], pr: (lo: Double, hi: Double),
                            color: NSColor, width: CGFloat, dash: [CGFloat] = []) {
        var started = false
        g.setStrokeColor(color.cgColor)
        g.setLineWidth(width)
        g.setLineDash(phase: 0, lengths: dash)
        g.beginPath()
        var local = 0
        for i in barRange {
            let x = xFor(localIndex: local)
            local += 1
            guard let v = values.value(i) else {
                started = false
                continue
            }
            let y = yFor(price: v, range: pr)
            if !started {
                g.move(to: CGPoint(x: x, y: y))
                started = true
            } else {
                g.addLine(to: CGPoint(x: x, y: y))
            }
        }
        g.strokePath()
        g.setLineDash(phase: 0, lengths: [])
    }

    private func drawMarkers(_ g: CGContext, ctx: MarketContext, pr: (lo: Double, hi: Double)) {
        // 按日期索引
        var byIndex: [Int: [TradingSignal]] = [:]
        var dateToIndex: [Date: Int] = [:]
        for i in barRange { dateToIndex[ctx.candles[i].date] = i }
        for m in markers {
            if let idx = dateToIndex[m.date] { byIndex[idx, default: []].append(m) }
        }

        for (idx, signals) in byIndex {
            let local = idx - barRange.lowerBound
            guard local >= 0 else { continue }
            let x = xFor(localIndex: local)
            let c = ctx.candles[idx]
            let sorted = signals.sorted { $0.score > $1.score }

            var upSlot = 0
            var downSlot = 0
            for sig in sorted.prefix(2) {
                let isBuySide = (sig.kind == .buy || sig.kind == .accumulate)
                let color = Theme.color(for: sig.kind)
                let size: CGFloat = 4.0
                var y: CGFloat
                if isBuySide {
                    y = yFor(price: c.low, range: pr) + 7 + CGFloat(upSlot) * 9
                    upSlot += 1
                } else {
                    y = yFor(price: c.high, range: pr) - 7 - CGFloat(downSlot) * 9
                    downSlot += 1
                }
                // 三角形
                g.setFillColor(color.alpha(0.95).cgColor)
                g.beginPath()
                if isBuySide {
                    g.move(to: CGPoint(x: x, y: y - size))
                    g.addLine(to: CGPoint(x: x - size * 0.85, y: y + size * 0.7))
                    g.addLine(to: CGPoint(x: x + size * 0.85, y: y + size * 0.7))
                } else {
                    g.move(to: CGPoint(x: x, y: y + size))
                    g.addLine(to: CGPoint(x: x - size * 0.85, y: y - size * 0.7))
                    g.addLine(to: CGPoint(x: x + size * 0.85, y: y - size * 0.7))
                }
                g.closePath()
                g.fillPath()

                // 单字
                let ch = sig.kind.shortLabel
                g.drawText(ch, at: CGPoint(x: x, y: isBuySide ? y + size + 1 : y - size - 10),
                           font: Fonts.ui(7, weight: .bold), color: color.alpha(0.9), align: .center)
            }
        }
    }

    /// 显式买卖点：买点红色上三角在最低价下方、卖点绿色下三角在最高价上方，
    /// 旁边带两字形态标签；"强"点三角形稍大，被门控否决的点半透明。
    private func drawTradePoints(_ g: CGContext, ctx: MarketContext, pr: (lo: Double, hi: Double)) {
        var byIndex: [Int: [TradePointSignal]] = [:]
        var dateToIndex: [Date: Int] = [:]
        for i in barRange { dateToIndex[ctx.candles[i].date] = i }
        for p in tradePoints {
            if let idx = dateToIndex[p.date] { byIndex[idx, default: []].append(p) }
        }

        for (idx, points) in byIndex {
            let local = idx - barRange.lowerBound
            guard local >= 0 else { continue }
            let x = xFor(localIndex: local)
            let c = ctx.candles[idx]
            var sorted = points
            sorted.sort { $0.strength > $1.strength }

            var buySlot = 0
            var sellSlot = 0
            for p in sorted.prefix(2) {
                let isBuy = p.direction == .buy
                let baseColor = isBuy ? Theme.up : Theme.down
                let color = p.isVetoed ? baseColor.alpha(0.35) : baseColor.alpha(0.95)
                let size: CGFloat = p.isStrong ? 5.0 : 4.0
                var y: CGFloat
                if isBuy {
                    y = yFor(price: c.low, range: pr) + 18 + CGFloat(buySlot) * 11
                    buySlot += 1
                } else {
                    y = yFor(price: c.high, range: pr) - 18 - CGFloat(sellSlot) * 11
                    sellSlot += 1
                }
                g.setFillColor(color.cgColor)
                g.beginPath()
                if isBuy {
                    g.move(to: CGPoint(x: x, y: y - size))
                    g.addLine(to: CGPoint(x: x - size * 0.85, y: y + size * 0.7))
                    g.addLine(to: CGPoint(x: x + size * 0.85, y: y + size * 0.7))
                } else {
                    g.move(to: CGPoint(x: x, y: y + size))
                    g.addLine(to: CGPoint(x: x - size * 0.85, y: y - size * 0.7))
                    g.addLine(to: CGPoint(x: x + size * 0.85, y: y - size * 0.7))
                }
                g.closePath()
                g.fillPath()

                let label = p.kind.shortLabel
                let weight: NSFont.Weight = p.isStrong ? .bold : .semibold
                g.drawText(label, at: CGPoint(x: x, y: isBuy ? y + size + 1 : y - size - 10),
                           font: Fonts.ui(7, weight: weight), color: color, align: .center)
            }
        }
    }

    /// 恐惧/贪婪信号历史：小菱形 + 两字标签。恐惧用蓝、贪婪用黄，与信号面板一致。
    /// 同一根 K 线已有同向买卖点时跳过，避免标记重叠刷屏。
    private func drawFearHistory(_ g: CGContext, ctx: MarketContext, pr: (lo: Double, hi: Double)) {
        var dateToIndex: [Date: Int] = [:]
        for i in barRange { dateToIndex[ctx.candles[i].date] = i }
        var tradePointKeys = Set<String>()
        for p in tradePoints {
            tradePointKeys.insert("\(p.date.timeIntervalSince1970)-\(p.direction.rawValue)")
        }

        var byIndex: [Int: [FearSignal]] = [:]
        for f in fearHistory {
            let key = "\(f.date.timeIntervalSince1970)-\(f.direction.rawValue)"
            if tradePointKeys.contains(key) { continue }
            if let idx = dateToIndex[f.date] { byIndex[idx, default: []].append(f) }
        }

        for (idx, signals) in byIndex {
            let local = idx - barRange.lowerBound
            guard local >= 0 else { continue }
            let x = xFor(localIndex: local)
            let c = ctx.candles[idx]
            var sorted = signals
            sorted.sort { $0.score > $1.score }
            guard let f = sorted.first else { continue }
            let isBuy = f.direction == .buy
            let color = f.sentiment == .fear ? Theme.accumulate.alpha(0.85) : Theme.risk.alpha(0.85)
            let size: CGFloat = 3.5
            let y: CGFloat = isBuy
                ? yFor(price: c.low, range: pr) + 29
                : yFor(price: c.high, range: pr) - 29
            g.setFillColor(color.cgColor)
            g.beginPath()
            g.move(to: CGPoint(x: x, y: y - size))
            g.addLine(to: CGPoint(x: x + size, y: y))
            g.addLine(to: CGPoint(x: x, y: y + size))
            g.addLine(to: CGPoint(x: x - size, y: y))
            g.closePath()
            g.fillPath()
            g.drawText(f.kind.shortLabel, at: CGPoint(x: x, y: isBuy ? y + size + 1 : y - size - 10),
                       font: Fonts.ui(7, weight: .semibold), color: color, align: .center)
        }
    }

    private func drawSeparator(_ g: CGContext) {
        g.strokeLine(from: CGPoint(x: 0, y: mainHeight + 1.5), to: CGPoint(x: bounds.width, y: mainHeight + 1.5),
                     color: Theme.border.alpha(0.7), width: 0.6)
    }

    // MARK: - 副图

    private func drawSubPanel(_ g: CGContext, ctx: MarketContext) {
        switch subIndicator {
        case .volume: drawVolume(g, ctx: ctx)
        case .macd: drawMACD(g, ctx: ctx)
        case .kdj: drawKDJ(g, ctx: ctx)
        case .rsi: drawRSI(g, ctx: ctx)
        }
        drawTimeAxis(g, ctx: ctx)
    }

    private func subLabel(_ g: CGContext, _ text: String) {
        g.drawText(text, at: CGPoint(x: 6, y: subTop + 2), font: Fonts.mono(8), color: Theme.textFaint)
    }

    private func drawVolume(_ g: CGContext, ctx: MarketContext) {
        let h = subHeight - 2
        var maxVol = 0.0
        for i in barRange { maxVol = max(maxVol, ctx.candles[i].volume) }
        guard maxVol > 0 else { return }

        var local = 0
        for i in barRange {
            let c = ctx.candles[i]
            let x = xFor(localIndex: local)
            local += 1
            let bh = CGFloat(c.volume / maxVol) * h
            let bw = barWidth() * 0.70
            let color = (c.isUp ? Theme.up : Theme.down).alpha(0.60)
            g.fillRect(CGRect(x: x - bw / 2, y: subTop + h - bh, width: bw, height: max(0.6, bh)), color)
        }

        // 5日均量线
        var started = false
        g.setStrokeColor(Theme.ma5.alpha(0.85).cgColor)
        g.setLineWidth(0.9)
        g.beginPath()
        var l2 = 0
        for i in barRange {
            let x = xFor(localIndex: l2)
            l2 += 1
            guard let v = ctx.volMA5.value(i) else { started = false; continue }
            let y = subTop + h - CGFloat(v / maxVol) * h
            if !started { g.move(to: CGPoint(x: x, y: y)); started = true }
            else { g.addLine(to: CGPoint(x: x, y: y)) }
        }
        g.strokePath()

        if let v = ctx.candles.last?.volume {
            subLabel(g, "VOL  \(Fmt.volume(v))")
        }
    }

    private func drawMACD(_ g: CGContext, ctx: MarketContext) {
        let h = subHeight - 2
        var lo = 0.0, hi = 0.0
        for i in barRange {
            if let v = ctx.macd.dif.value(i) { lo = min(lo, v); hi = max(hi, v) }
            if let v = ctx.macd.dea.value(i) { lo = min(lo, v); hi = max(hi, v) }
            if let v = ctx.macd.hist.value(i) { lo = min(lo, v); hi = max(hi, v) }
        }
        let span = max(hi - lo, 1e-9)
        let base = self.subTop
        let yFor: (Double) -> CGFloat = { v in base + h - CGFloat((v - lo) / span) * h }
        let zeroY = yFor(0)

        var local = 0
        for i in barRange {
            let x = xFor(localIndex: local)
            local += 1
            guard let v = ctx.macd.hist.value(i) else { continue }
            let y = yFor(v)
            let bw = barWidth() * 0.62
            g.fillRect(CGRect(x: x - bw / 2, y: min(y, zeroY), width: bw, height: max(0.6, abs(y - zeroY))),
                       (v >= 0 ? Theme.up : Theme.down).alpha(0.72))
        }

        g.strokeLine(from: CGPoint(x: 0, y: zeroY), to: CGPoint(x: plotWidth, y: zeroY),
                     color: Theme.textFaint.alpha(0.35), width: 0.5)

        for (arr, color) in [(ctx.macd.dif, Theme.ma5), (ctx.macd.dea, Theme.ma20)] {
            var started = false
            g.setStrokeColor(color.cgColor)
            g.setLineWidth(0.9)
            g.beginPath()
            var l2 = 0
            for i in barRange {
                let x = xFor(localIndex: l2)
                l2 += 1
                guard let v = arr.value(i) else { started = false; continue }
                let y = subTop + h - CGFloat((v - lo) / span) * h
                if !started { g.move(to: CGPoint(x: x, y: y)); started = true }
                else { g.addLine(to: CGPoint(x: x, y: y)) }
            }
            g.strokePath()
        }

        if let dif = ctx.macd.dif.lastFinite, let dea = ctx.macd.dea.lastFinite {
            subLabel(g, "MACD  DIF \(Fmt.price(dif))  DEA \(Fmt.price(dea))")
        }
    }

    private func drawKDJ(_ g: CGContext, ctx: MarketContext) {
        let h = subHeight - 2
        let yFor: (Double) -> CGFloat = { v in
            let clamped = min(max(v, -10), 110)
            return self.subTop + h - CGFloat((clamped + 10) / 120) * h
        }
        for level in [20.0, 50.0, 80.0] {
            let y = yFor(level)
            g.strokeLine(from: CGPoint(x: 0, y: y), to: CGPoint(x: plotWidth, y: y),
                         color: Theme.grid.alpha(0.7), width: 0.5, dash: level == 50 ? [2, 3] : [])
        }
        for (arr, color) in [(ctx.kdj.k, Theme.ma5), (ctx.kdj.d, Theme.ma20), (ctx.kdj.j, Theme.distribute)] {
            var started = false
            g.setStrokeColor(color.cgColor)
            g.setLineWidth(0.9)
            g.beginPath()
            var local = 0
            for i in barRange {
                let x = xFor(localIndex: local)
                local += 1
                guard let v = arr.value(i) else { started = false; continue }
                let y = yFor(v)
                if !started { g.move(to: CGPoint(x: x, y: y)); started = true }
                else { g.addLine(to: CGPoint(x: x, y: y)) }
            }
            g.strokePath()
        }
        if let k = ctx.kdj.k.lastFinite, let d = ctx.kdj.d.lastFinite, let j = ctx.kdj.j.lastFinite {
            subLabel(g, "KDJ  K \(Fmt.price(k, decimals: 1))  D \(Fmt.price(d, decimals: 1))  J \(Fmt.price(j, decimals: 1))")
        }
    }

    private func drawRSI(_ g: CGContext, ctx: MarketContext) {
        let h = subHeight - 2
        let yFor: (Double) -> CGFloat = { v in
            self.subTop + h - CGFloat(min(max(v, 0), 100) / 100) * h
        }
        for level in [30.0, 50.0, 70.0] {
            let y = yFor(level)
            g.strokeLine(from: CGPoint(x: 0, y: y), to: CGPoint(x: plotWidth, y: y),
                         color: Theme.grid.alpha(0.75), width: 0.5, dash: level == 50 ? [2, 3] : [])
        }
        for (arr, color) in [(ctx.rsi6, Theme.ma5), (ctx.rsi14, Theme.ma20)] {
            var started = false
            g.setStrokeColor(color.cgColor)
            g.setLineWidth(0.9)
            g.beginPath()
            var local = 0
            for i in barRange {
                let x = xFor(localIndex: local)
                local += 1
                guard let v = arr.value(i) else { started = false; continue }
                let y = yFor(v)
                if !started { g.move(to: CGPoint(x: x, y: y)); started = true }
                else { g.addLine(to: CGPoint(x: x, y: y)) }
            }
            g.strokePath()
        }
        if let r6 = ctx.rsi6.lastFinite, let r14 = ctx.rsi14.lastFinite {
            subLabel(g, "RSI  RSI6 \(Fmt.price(r6, decimals: 1))  RSI14 \(Fmt.price(r14, decimals: 1))")
        }
    }

    private func drawTimeAxis(_ g: CGContext, ctx: MarketContext) {
        let count = barRange.count
        guard count > 1 else { return }
        let step = max(1, count / 6)
        let y = bounds.height - bottomAxisHeight + 4
        var local = 0
        for i in barRange {
            if local % step == 0 {
                let x = xFor(localIndex: local)
                let label = intraday
                    ? Fmt.intradayFormatter.string(from: ctx.candles[i].date)
                    : Fmt.shortDateFormatter.string(from: ctx.candles[i].date)
                g.drawText(label, at: CGPoint(x: x, y: y), font: Fonts.mono(8),
                           color: Theme.textFaint, align: .center)
            }
            local += 1
        }
        // 右侧轴竖线
        g.strokeLine(from: CGPoint(x: plotWidth, y: 0), to: CGPoint(x: plotWidth, y: bounds.height),
                     color: Theme.border.alpha(0.5), width: 0.5)
    }

    // MARK: - 十字光标

    private func drawCrosshair(_ g: CGContext, ctx: MarketContext, range pr: (lo: Double, hi: Double)) {
        guard let idx = crosshairIndex, barRange.contains(idx) else { return }
        let local = idx - barRange.lowerBound
        let x = xFor(localIndex: local)
        let c = ctx.candles[idx]

        g.strokeLine(from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: bounds.height - bottomAxisHeight),
                     color: Theme.textDim.alpha(0.45), width: 0.6, dash: [3, 3])
        _ = 0

        if let p = crosshairPoint, p.y < mainHeight {
            g.strokeLine(from: CGPoint(x: labelGutter, y: p.y), to: CGPoint(x: plotWidth, y: p.y),
                         color: Theme.textDim.alpha(0.45), width: 0.6, dash: [3, 3])
            // 价格刻度
            let price = pr.lo + (pr.hi - pr.lo) * Double((mainHeight - p.y) / mainHeight)
            g.fillRoundedRect(CGRect(x: plotWidth + 1, y: p.y - 7.5, width: axisWidth - 3, height: 15),
                              radius: 2.5, color: Theme.panel3)
            g.drawText(Fmt.price(price, decimals: priceDecimals(price)),
                       at: CGPoint(x: plotWidth + axisWidth / 2, y: p.y - 6),
                       font: Fonts.mono(9, weight: .medium), color: Theme.text, align: .center)
        }

        // 日期刻度
        let dateText = intraday
            ? Fmt.intradayFormatter.string(from: c.date)
            : Fmt.dateFormatter.string(from: c.date)
        g.fillRoundedRect(CGRect(x: x - 34, y: bounds.height - bottomAxisHeight + 1, width: 68, height: 14),
                          radius: 2.5, color: Theme.panel3)
        g.drawText(dateText, at: CGPoint(x: x, y: bounds.height - bottomAxisHeight + 3),
                   font: Fonts.mono(8.5), color: Theme.text, align: .center)

        // 信息浮层
        drawInfoOverlay(g, ctx: ctx, index: idx)
    }

    private func drawInfoOverlay(_ g: CGContext, ctx: MarketContext, index: Int) {
        let c = ctx.candles[index]
        let prevClose = index > 0 ? ctx.candles[index - 1].close : c.open
        let chg = prevClose > 0 ? (c.close / prevClose - 1) * 100 : 0
        let color = Theme.color(change: chg)

        var lines: [(String, NSColor)] = []
        lines.append((Fmt.date(c.date, intraday: intraday), Theme.text))
        lines.append(("开 \(Fmt.price(c.open))  高 \(Fmt.price(c.high))", Theme.textDim))
        lines.append(("低 \(Fmt.price(c.low))  收 \(Fmt.price(c.close))", Theme.textDim))
        lines.append((Fmt.pct(chg), color))
        lines.append(("量 \(Fmt.volume(c.volume))", Theme.textDim))
        if let vr = ctx.volRatio.value(index) {
            lines.append(("量比 \(Fmt.price(vr))", Theme.textDim))
        }
        if let r = ctx.rsi14.value(index) {
            lines.append(("RSI14 \(Fmt.price(r, decimals: 1))", Theme.textDim))
        }

        let padW: CGFloat = 6
        var maxW: CGFloat = 0
        for (text, _) in lines {
            let attrs: [NSAttributedString.Key: Any] = [.font: Fonts.mono(9), .foregroundColor: Theme.text]
            maxW = max(maxW, (text as NSString).size(withAttributes: attrs).width)
        }
        let lineH: CGFloat = 12.5
        let boxW = maxW + padW * 2
        let boxH = CGFloat(lines.count) * lineH + padW

        // 根据光标位置左右翻转，避免遮挡
        let local = index - barRange.lowerBound
        let x = xFor(localIndex: local)
        var boxX = x + 12
        if boxX + boxW > plotWidth { boxX = x - boxW - 12 }
        let boxY = CGFloat(6)

        g.fillRoundedRect(CGRect(x: boxX, y: boxY, width: boxW, height: boxH), radius: 4, color: Theme.bg.alpha(0.93))
        g.strokeRoundedRect(CGRect(x: boxX, y: boxY, width: boxW, height: boxH), radius: 4,
                            color: Theme.border.alpha(0.9), width: 0.6)

        var y = boxY + padW / 2
        for (text, col) in lines {
            g.drawText(text, at: CGPoint(x: boxX + padW, y: y), font: Fonts.mono(9), color: col)
            y += lineH
        }
    }

    private func priceDecimals(_ v: Double) -> Int {
        if v >= 1000 { return 2 }
        if v >= 100 { return 2 }
        if v >= 10 { return 2 }
        return 3
    }

    // MARK: - 交互

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        crosshairPoint = p
        updateCrosshairIndex(at: p)
    }

    override func mouseExited(with event: NSEvent) {
        crosshairIndex = nil
        crosshairPoint = nil
        needsDisplay = true
    }

    private func updateCrosshairIndex(at p: CGPoint) {
        guard total > 0, !barRange.isEmpty else { return }
        let local = localIndex(forX: p.x)
        guard local >= 0 else { crosshairIndex = nil; needsDisplay = true; return }
        let idx = barRange.lowerBound + local
        if barRange.contains(idx) {
            crosshairIndex = idx
        } else {
            crosshairIndex = nil
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !isDragging {
            isDragging = true
            dragStartOffset = effectiveOffset
            dragStartPoint = p
        }
        let bw = barWidth()
        guard bw > 0 else { return }
        let deltaBars = Int(((p.x - dragStartPoint.x) / bw).rounded())
        let maxOffset = max(0, total - visibleBars)
        scrollOffset = min(maxOffset, max(0, dragStartOffset + deltaBars))
        crosshairPoint = p
        updateCrosshairIndex(at: p)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    override func scrollWheel(with event: NSEvent) {
        guard total > 0 else { return }
        // 触控板捏合通过 magnification 处理，滚轮处理水平/垂直平移与缩放
        if event.hasPreciseScrollingDeltas && event.modifierFlags.contains(.option) {
            let factor = 1.0 - Double(event.scrollingDeltaY) * 0.01
            zoom(by: factor)
            return
        }
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            let bw = barWidth()
            guard bw > 0 else { return }
            let deltaBars = Int((event.scrollingDeltaX / bw).rounded())
            let maxOffset = max(0, total - visibleBars)
            scrollOffset = min(maxOffset, max(0, effectiveOffset + deltaBars))
            needsDisplay = true
        } else {
            let factor = 1.0 + Double(event.scrollingDeltaY) * 0.005
            zoom(by: factor)
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1.0 - Double(event.magnification))
    }

    private func zoom(by factor: Double) {
        guard total > 0 else { return }
        let newBars = Int((Double(visibleBars) * factor).rounded())
        let clamped = min(max(30, newBars), min(500, max(30, total)))
        guard clamped != visibleBars else { return }
        // 以右端为锚点缩放
        visibleBars = clamped
        scrollOffset = min(scrollOffset, max(0, total - visibleBars))
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: // ←
            scrollOffset = min(max(0, total - visibleBars), scrollOffset + max(1, visibleBars / 10))
            needsDisplay = true
        case 124: // →
            scrollOffset = max(0, scrollOffset - max(1, visibleBars / 10))
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }
}
