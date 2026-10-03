import AppKit
import SwiftUI

/// AppKit 的毛玻璃视图，SwiftUI 里当背景用。
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var isEmphasized = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = isEmphasized
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.isEmphasized = isEmphasized
    }
}

/// 卡片：半透明材质加细边，设置页用它。
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 14
    var prominent = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            return AnyView(content.glassEffect(.regular, in: shape))
        }
        #endif
        return AnyView(
            content
                .background(prominent ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.thinMaterial), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        )
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 14, prominent: Bool = false) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, prominent: prominent))
    }
}

/// 配置颜色的小圆点，带一圈柔光。
struct ColorDot: View {
    var hex: String
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(Color(hex: hex))
            .frame(width: size, height: size)
            .shadow(color: Color(hex: hex).opacity(0.6), radius: 3)
    }
}
