import AppKit
import CoreImage
import ScreenCaptureKit

/// 识别二维码：剪贴板或文件里的图片，或者屏幕上的（网页、聊天窗口里的节点二维码）。
enum QRScanner {
    /// 图片里所有二维码的内容。
    static func decode(_ image: CGImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: image)) ?? []
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    static func decode(_ image: NSImage) -> [String] {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return [] }
        return decode(cgImage)
    }

    /// 剪贴板里的图片上的二维码。
    static func fromPasteboard() -> [String] {
        guard let image = NSImage(pasteboard: NSPasteboard.general) else { return [] }
        return decode(image)
    }

    static func fromFile(_ url: URL) -> [String] {
        guard let image = NSImage(contentsOf: url) else { return [] }
        return decode(image)
    }

    /// 扫描所有显示器上的二维码。要「屏幕录制」权限，第一次会弹出系统的询问。
    static func scanScreens() async throws -> [String] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var results: [String] = []
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = display.width * 2
            configuration.height = display.height * 2
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            for text in decode(image) where !results.contains(text) {
                results.append(text)
            }
        }
        return results
    }
}
