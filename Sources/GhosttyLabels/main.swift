import Cocoa
import CoreGraphics

private struct GhosttyWindow: Hashable {
    let id: CGWindowID
    let title: String
    let bounds: CGRect
}

private enum LabelPosition: String {
    case topLeft = "top-left"
    case topCenter = "top-center"
    case topRight = "top-right"

    static var configured: LabelPosition {
        let raw = ProcessInfo.processInfo.environment["GHOSTTY_LABEL_POSITION"] ?? "top-right"
        return LabelPosition(rawValue: raw) ?? .topRight
    }
}

private final class BadgeView: NSView {
    var text: String {
        didSet {
            needsDisplay = true
        }
    }

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = self.bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor(calibratedRed: 1.0, green: 0.22, blue: 0.20, alpha: 0.94).setFill()
        path.fill()

        NSColor(calibratedWhite: 0.04, alpha: 0.75).setStroke()
        path.lineWidth = 1
        path.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]

        let textRect = bounds.insetBy(dx: 12, dy: 5)
        (text as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            attributes: attributes
        )
    }
}

private final class LabelWindow: NSWindow {
    let badgeView: BadgeView

    init(text: String, frame: NSRect) {
        self.badgeView = BadgeView(text: text)
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        level = .statusBar
        contentView = badgeView
    }
}

private final class LabelController {
    private var overlays: [CGWindowID: LabelWindow] = [:]
    private let position = LabelPosition.configured
    private let alwaysShow = ProcessInfo.processInfo.environment["GHOSTTY_LABEL_ALWAYS"] == "1"
    private let activeLabelAlpha: CGFloat = 1
    private let inactiveLabelAlpha: CGFloat = 0.35
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        refresh()
        print("ghostty-labels running. Set Ghostty tab titles with cmd+ctrl+l. Stop with ctrl+c.")
    }

    private func refresh() {
        guard alwaysShow || isGhosttyFrontmost() else {
            removeAllOverlays()
            return
        }

        let windows = visibleGhosttyWindows()
        let liveIDs = Set(windows.map(\.id))

        for staleID in overlays.keys where !liveIDs.contains(staleID) {
            overlays[staleID]?.close()
            overlays.removeValue(forKey: staleID)
        }

        // CGWindowListCopyWindowInfo returns windows front-to-back, so the first
        // visible Ghostty window is the active one when Ghostty is focused.
        let activeWindowID = isGhosttyFrontmost() ? windows.first?.id : nil

        for ghosttyWindow in windows {
            let frame = labelFrame(for: ghosttyWindow)
            let isActiveWindow = ghosttyWindow.id == activeWindowID
            if let overlay = overlays[ghosttyWindow.id] {
                overlay.badgeView.text = ghosttyWindow.title
                overlay.alphaValue = isActiveWindow ? activeLabelAlpha : inactiveLabelAlpha
                overlay.setFrame(frame, display: true)
            } else {
                let overlay = LabelWindow(text: ghosttyWindow.title, frame: frame)
                overlay.alphaValue = isActiveWindow ? activeLabelAlpha : inactiveLabelAlpha
                overlays[ghosttyWindow.id] = overlay
            }
        }

        for ghosttyWindow in windows where ghosttyWindow.id != activeWindowID {
            overlays[ghosttyWindow.id]?.orderFrontRegardless()
        }

        if let activeWindowID {
            overlays[activeWindowID]?.orderFrontRegardless()
        }
    }

    private func removeAllOverlays() {
        for overlay in overlays.values {
            overlay.close()
        }
        overlays.removeAll()
    }

    private func isGhosttyFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.localizedName == "Ghostty"
    }

    private func visibleGhosttyWindows() -> [GhosttyWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return rawWindows.compactMap { info in
            guard
                (info[kCGWindowOwnerName as String] as? String) == "Ghostty",
                (info[kCGWindowLayer as String] as? Int) == 0,
                let id = info[kCGWindowNumber as String] as? UInt32,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else {
                return nil
            }

            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0 else {
                return nil
            }

            let rawTitle = (info[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle?.isEmpty == false ? rawTitle! : "Ghostty"

            return GhosttyWindow(id: CGWindowID(id), title: title, bounds: bounds)
        }
    }

    private func labelFrame(for window: GhosttyWindow) -> NSRect {
        let size = badgeSize(for: window.title)
        let x: CGFloat

        switch position {
        case .topLeft:
            x = window.bounds.minX + 18
        case .topCenter:
            x = window.bounds.midX - size.width / 2
        case .topRight:
            x = window.bounds.maxX - size.width - 18
        }

        let y = appKitY(forTopEdgeOf: window.bounds) - size.height - 42
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func badgeSize(for text: String) -> NSSize {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ]
        let measured = (text as NSString).size(withAttributes: attributes)
        return NSSize(width: min(max(measured.width + 32, 86), 360), height: 30)
    }

    private func appKitY(forTopEdgeOf cgBounds: CGRect) -> CGFloat {
        let display = NSScreen.screens.first { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
            return displayBounds.intersects(cgBounds)
        }

        guard
            let screen = display,
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            let maxY = NSScreen.screens.map(\.frame.maxY).max() ?? 0
            return maxY - cgBounds.minY
        }

        let displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
        let distanceFromDisplayTop = cgBounds.minY - displayBounds.minY
        return screen.frame.maxY - distanceFromDisplayTop
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
private let controller = LabelController()
controller.start()
RunLoop.main.run()
