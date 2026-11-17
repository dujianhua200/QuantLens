import AppKit

// MARK: - 配色（深色专业交易终端风格）

enum Theme {
    // 背景层级
    static let bg = NSColor(srgbRed: 0.047, green: 0.055, blue: 0.071, alpha: 1)
    static let panel = NSColor(srgbRed: 0.073, green: 0.086, blue: 0.110, alpha: 1)
    static let panel2 = NSColor(srgbRed: 0.094, green: 0.110, blue: 0.137, alpha: 1)
    static let panel3 = NSColor(srgbRed: 0.118, green: 0.137, blue: 0.169, alpha: 1)
    static let border = NSColor(srgbRed: 0.169, green: 0.196, blue: 0.235, alpha: 1)
    static let grid = NSColor(srgbRed: 0.149, green: 0.169, blue: 0.200, alpha: 1)

    // A股习惯：红涨绿跌
    static let up = NSColor(srgbRed: 0.945, green: 0.290, blue: 0.322, alpha: 1)
    static let down = NSColor(srgbRed: 0.180, green: 0.760, blue: 0.522, alpha: 1)
    static let flat = NSColor(srgbRed: 0.560, green: 0.612, blue: 0.686, alpha: 1)

    // 文字
    static let text = NSColor(srgbRed: 0.910, green: 0.929, blue: 0.953, alpha: 1)
    static let textDim = NSColor(srgbRed: 0.560, green: 0.612, blue: 0.686, alpha: 1)
    static let textFaint = NSColor(srgbRed: 0.396, green: 0.443, blue: 0.510, alpha: 1)

    // 强调色
    static let accent = NSColor(srgbRed: 0.353, green: 0.620, blue: 1.000, alpha: 1)

    // 四类信号
    static let buy = NSColor(srgbRed: 0.270, green: 0.820, blue: 0.620, alpha: 1)
    static let risk = NSColor(srgbRed: 1.000, green: 0.722, blue: 0.250, alpha: 1)
    static let accumulate = NSColor(srgbRed: 0.420, green: 0.722, blue: 1.000, alpha: 1)
    static let distribute = NSColor(srgbRed: 0.949, green: 0.451, blue: 0.718, alpha: 1)

    // 均线
    static let ma5 = NSColor(srgbRed: 1.000, green: 0.851, blue: 0.353, alpha: 1)
    static let ma10 = NSColor(srgbRed: 0.980, green: 0.600, blue: 0.851, alpha: 1)
    static let ma20 = NSColor(srgbRed: 0.451, green: 0.780, blue: 1.000, alpha: 1)
    static let ma60 = NSColor(srgbRed: 0.722, green: 0.620, blue: 1.000, alpha: 1)

    static func color(for kind: SignalKind) -> NSColor {
        switch kind {
        case .buy: return buy
        case .risk: return risk
        case .accumulate: return accumulate
        case .distribute: return distribute
        }
    }

    static func color(change: Double) -> NSColor {
        change > 0.00001 ? up : (change < -0.00001 ? down : flat)
    }

    static func color(change: CGFloat) -> NSColor {
        color(change: Double(change))
    }
}

// MARK: - 字体

enum Fonts {
    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    static func ui(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
}

// MARK: - NSColor 便捷

extension NSColor {
    func alpha(_ a: CGFloat) -> NSColor {
        withAlphaComponent(a)
    }
}

// MARK: - 绘图辅助

extension CGContext {
    func fillRect(_ rect: CGRect, _ color: NSColor) {
        setFillColor(color.cgColor)
        fill(rect)
    }

    func strokeLine(from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat, dash: [CGFloat] = []) {
        setStrokeColor(color.cgColor)
        setLineWidth(width)
        if dash.isEmpty {
            setLineDash(phase: 0, lengths: [])
        } else {
            setLineDash(phase: 0, lengths: dash)
        }
        beginPath()
        move(to: from)
        addLine(to: to)
        strokePath()
        setLineDash(phase: 0, lengths: [])
    }

    func fillRoundedRect(_ rect: CGRect, radius: CGFloat, color: NSColor) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        setFillColor(color.cgColor)
        addPath(path)
        fillPath()
    }

    func strokeRoundedRect(_ rect: CGRect, radius: CGFloat, color: NSColor, width: CGFloat) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        setStrokeColor(color.cgColor)
        setLineWidth(width)
        addPath(path)
        strokePath()
    }

    /// 绘制文本（左上角为锚点原点）
    func drawText(_ text: String, at point: CGPoint, font: NSFont, color: NSColor, align: TextAlign = .left) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let ns = text as NSString
        let size = ns.size(withAttributes: attrs)
        var x = point.x
        switch align {
        case .left: x = point.x
        case .center: x = point.x - size.width / 2
        case .right: x = point.x - size.width
        }
        ns.draw(at: CGPoint(x: x, y: point.y), withAttributes: attrs)
    }

    enum TextAlign { case left, center, right }
}
