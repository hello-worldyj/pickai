import AppKit
import CoreGraphics

enum ScreenshotCapture {
    static func requestPermissionIfNeeded() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    /// Captures the whole display under the given point (screenshot-style), downscaled to keep upload
    /// size reasonable. Works regardless of what's frontmost — another app's window, the Desktop, or
    /// nothing at all — since it doesn't depend on matching a specific app/window.
    static func captureScreen(around point: NSPoint) -> (image: NSImage, pngData: Data)? {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        guard let screen,
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        guard let cgImage = CGDisplayCreateImage(displayID) else {
            return nil
        }

        let fullImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let scaled = downscale(fullImage, maxDimension: 1400)

        guard let tiffData = scaled.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        return (scaled, pngData)
    }

    private static func downscale(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let size = image.size
        let scale = min(1.0, maxDimension / max(size.width, size.height))
        guard scale < 1.0 else { return image }

        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize), from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1.0)
        resized.unlockFocus()
        return resized
    }
}
