import AppKit
import SwiftUI

@main
struct Audio2TxtDesktopApp: App {
    init() {
        DispatchQueue.main.async {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            if let icon = DockIconFactory.makeIcon() {
                app.applicationIconImage = icon
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowResizability(.contentSize)
    }
}

enum DockIconFactory {
    static func makeIcon() -> NSImage? {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()

        let bgRect = NSRect(origin: .zero, size: size)
        NSColor(calibratedRed: 0.08, green: 0.47, blue: 0.93, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 112, yRadius: 112).fill()

        let waveRect = NSRect(x: 126, y: 142, width: 260, height: 176)
        if let waveform = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) {
            waveform.isTemplate = false
            NSColor.white.set()
            waveform.draw(in: waveRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        let text = "A2T"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attrs)
        let textRect = NSRect(
            x: (size.width - textSize.width) / 2,
            y: 52,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attrs)

        image.unlockFocus()
        return image
    }
}
