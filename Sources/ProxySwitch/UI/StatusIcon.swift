import AppKit
import CoreText
import SwiftUI

/// 菜单栏图标的状态。
enum StatusIconState: Equatable {
    case off
    case on(NSColor)
    case external
    case warning(NSColor)
    case error
}

/// 菜单栏图标：一个“开关”造型，圆角轨道加圆形滑块，滑块在右表示开启。关闭时是模板图，跟随菜单栏的深浅色。
/// 显示网速时把开关和两行小字合成一张图：按钮自己排版多行标题会让文字偏上，合成后两行文字的墨迹以开关的中线为中心。
enum StatusIcon {
    static let amber = NSColor(red: 0xd9 / 255, green: 0x77 / 255, blue: 0x06 / 255, alpha: 1)
    static let red = NSColor(red: 0xdc / 255, green: 0x26 / 255, blue: 0x26 / 255, alpha: 1)

    static let iconSize = NSSize(width: 24, height: 14)
    /// 网速的字体：等宽数字，宽度稳定，图标不会跟着抖。
    static let speedFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
    /// 两行网速基线之间的距离。
    static let speedLinePitch: CGFloat = 9.5
    /// 开关和文字之间的间距。
    static let speedGap: CGFloat = 4
    /// 带网速时整张图的高度（两行 8.5 号字刚好放下，菜单栏里也放得下）。
    static let speedHeight: CGFloat = 20

    static func image(for state: StatusIconState) -> NSImage {
        let image = NSImage(size: iconSize, flipped: false) { rect in
            draw(state, in: rect)
            return true
        }
        image.isTemplate = state == .off
        return image
    }

    /// 开关加两行网速（上行、下行）。textColor 是菜单栏当前外观下的文字颜色；关闭状态是模板图，颜色由系统决定。
    static func image(for state: StatusIconState, upload: String, download: String, textColor: CGColor) -> NSImage {
        let lines = [makeLine("↑" + upload), makeLine("↓" + download)]
        let widths = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
        let textWidth = ceil(widths.max() ?? 0)
        let size = NSSize(width: iconSize.width + speedGap + textWidth, height: speedHeight)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let iconRect = NSRect(x: rect.minX, y: rect.midY - iconSize.height / 2, width: iconSize.width, height: iconSize.height)
            draw(state, in: iconRect)
            // 文字：先量出两行的墨迹范围，让墨迹的整体中线正好落在开关的中线上，不依赖字体的名义行高。
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = .zero
            let ink = lines.map { CTLineGetImageBounds($0, context) }
            let bottomBaseline = rect.midY - (speedLinePitch + ink[0].maxY + ink[1].minY) / 2
            let baselines = [bottomBaseline + speedLinePitch, bottomBaseline]
            context.setFillColor(state == .off ? NSColor.black.cgColor : textColor)
            for (index, line) in lines.enumerated() {
                context.textPosition = CGPoint(x: rect.maxX - widths[index], y: baselines[index])
                CTLineDraw(line, context)
            }
            context.restoreGState()
            return true
        }
        image.isTemplate = state == .off
        return image
    }

    private static func makeLine(_ text: String) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: speedFont,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
    }

    /// 把图渲染成位图（测试里检查对齐用）。
    static func bitmap(of image: NSImage, scale: CGFloat) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return nil
        }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        return rep
    }

    private static func draw(_ state: StatusIconState, in rect: NSRect) {
        // 关闭状态用 destinationOut 挖空滑块，画完要把合成模式恢复，后面的文字才能正常画上去。
        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        let track = rect.insetBy(dx: 0.5, dy: 0.5)
        let radius = track.height / 2
        let trackPath = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
        let knobInset: CGFloat = 2.5
        let knobDiameter = track.height - knobInset * 2
        func knobRect(right: Bool) -> NSRect {
            let x = right ? track.maxX - knobInset - knobDiameter : track.minX + knobInset
            return NSRect(x: x, y: track.minY + knobInset, width: knobDiameter, height: knobDiameter)
        }
        switch state {
        case .off:
            NSColor.black.setFill()
            trackPath.fill()
            // 模板图只看透明度：把滑块“挖空”，得到一个空心的滑块。
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: knobRect(right: false)).fill()
        case .on(let color):
            color.setFill()
            trackPath.fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knobRect(right: true)).fill()
        case .external:
            amber.setFill()
            trackPath.fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knobRect(right: true)).fill()
        case .warning(let color):
            color.setFill()
            trackPath.fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knobRect(right: true)).fill()
            red.setFill()
            NSBezierPath(ovalIn: knobRect(right: true).insetBy(dx: 1.5, dy: 1.5)).fill()
        case .error:
            red.setFill()
            trackPath.fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knobRect(right: false)).fill()
        }
    }
}

extension NSColor {
    /// 解析 #rrggbb。
    convenience init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: text).scanHexInt64(&value)
        let red = CGFloat((value >> 16) & 0xff) / 255
        let green = CGFloat((value >> 8) & 0xff) / 255
        let blue = CGFloat(value & 0xff) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

extension Color {
    init(hex: String) {
        self.init(nsColor: NSColor(hex: hex))
    }
}
