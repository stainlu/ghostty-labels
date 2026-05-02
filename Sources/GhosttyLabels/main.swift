import Cocoa
import CoreGraphics

private struct GhosttyWindow: Hashable {
    let id: CGWindowID
    let title: String
    let bounds: CGRect
}

private typealias WindowGroupID = String

private struct DetectedGhosttyWindowGroup {
    let windowIDs: Set<CGWindowID>
    let title: String
    let bounds: CGRect
}

private struct GhosttyWindowGroup {
    let id: WindowGroupID
    let windowIDs: Set<CGWindowID>
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
    var onClick: (() -> Void)?

    var text: String {
        didSet {
            needsDisplay = true
        }
    }

    var isActive: Bool = true {
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
        let fillColor = isActive
            ? NSColor(calibratedRed: 1.0, green: 0.22, blue: 0.20, alpha: 0.96)
            : NSColor(calibratedWhite: 0.34, alpha: 0.96)
        fillColor.setFill()
        path.fill()

        let strokeColor = isActive
            ? NSColor(calibratedWhite: 0.04, alpha: 0.75)
            : NSColor(calibratedWhite: 0.12, alpha: 0.85)
        strokeColor.setStroke()
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

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class LabelWindow: NSPanel {
    let badgeView: BadgeView
    var groupID: WindowGroupID
    var onEdit: ((WindowGroupID, String) -> Void)?
    var onMouseDown: ((NSPoint) -> Void)?

    init(groupID: WindowGroupID, text: String, frame: NSRect) {
        self.groupID = groupID
        self.badgeView = BadgeView(text: text)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        level = .statusBar
        badgeView.onClick = { [weak self] in
            guard let self else {
                return
            }
            self.onEdit?(self.groupID, self.badgeView.text)
        }
        contentView = badgeView
    }

    override var canBecomeKey: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onEdit?(groupID, badgeView.text)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            onMouseDown?(NSEvent.mouseLocation)
        }

        super.sendEvent(event)
    }
}

private final class LabelController {
    private var overlays: [WindowGroupID: LabelWindow] = [:]
    private var windowLabels: [WindowGroupID: String] = [:]
    private var windowIDToGroupID: [CGWindowID: WindowGroupID] = [:]
    private var knownBoundsByGroupID: [WindowGroupID: CGRect] = [:]
    private var knownWindowIDsByGroupID: [WindowGroupID: Set<CGWindowID>] = [:]
    private var nextWindowGroupNumber = 1
    private let position = LabelPosition.configured
    private let alwaysShow = ProcessInfo.processInfo.environment["GHOSTTY_LABEL_ALWAYS"] == "1"
    private var isEditing = false
    private var pendingEditGroupID: WindowGroupID?
    private var lastActiveGroupID: WindowGroupID?
    private var timer: Timer?
    private var eventMonitorTokens: [Any] = []

    func start() {
        installEventMonitors()

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        refresh()
        print("ghostty-labels running. Set Ghostty tab titles with cmd+ctrl+l. Stop with ctrl+c.")
    }

    private func refresh() {
        guard !isEditing else {
            return
        }

        let ghosttyFrontmost = isGhosttyFrontmost()
        let helperFrontmost = isHelperFrontmost()
        guard alwaysShow || ghosttyFrontmost || helperFrontmost else {
            removeAllOverlays()
            return
        }

        let groups = assignStableIDs(to: detectPhysicalWindows(visibleGhosttyWindows()))
        let liveIDs = Set(groups.map(\.id))

        for staleID in overlays.keys where !liveIDs.contains(staleID) {
            overlays[staleID]?.close()
            overlays.removeValue(forKey: staleID)
            windowLabels.removeValue(forKey: staleID)
        }

        // CGWindowListCopyWindowInfo returns windows front-to-back. Ghostty uses
        // native macOS tabs, so multiple tab "windows" can share one frame; after
        // grouping, the first group is the selected physical Ghostty window.
        if ghosttyFrontmost {
            lastActiveGroupID = groups.first?.id
        }
        let activeGroupID = liveIDs.contains(lastActiveGroupID ?? "") ? lastActiveGroupID : groups.first?.id

        var nextWindowIDToGroupID: [CGWindowID: WindowGroupID] = [:]
        for group in groups {
            let label = labelText(for: group)
            let frame = labelFrame(for: group, label: label)
            let isActiveWindow = group.id == activeGroupID
            group.windowIDs.forEach { nextWindowIDToGroupID[$0] = group.id }

            if let overlay = overlays[group.id] {
                overlay.groupID = group.id
                overlay.badgeView.text = label
                overlay.badgeView.isActive = isActiveWindow
                overlay.alphaValue = 1
                overlay.setFrame(frame, display: true)
            } else {
                let overlay = LabelWindow(groupID: group.id, text: label, frame: frame)
                overlay.badgeView.isActive = isActiveWindow
                overlay.alphaValue = 1
                overlay.onEdit = { [weak self] groupID, currentLabel in
                    self?.scheduleEditLabel(for: groupID, currentLabel: currentLabel)
                }
                overlay.onMouseDown = { [weak self] point in
                    _ = self?.editLabelIfNeeded(at: point)
                }
                overlays[group.id] = overlay
            }
        }
        windowIDToGroupID = nextWindowIDToGroupID

        for group in groups where group.id != activeGroupID {
            overlays[group.id]?.orderFrontRegardless()
        }

        if let activeGroupID {
            overlays[activeGroupID]?.orderFrontRegardless()
        }
    }

    private func removeAllOverlays() {
        for overlay in overlays.values {
            overlay.close()
        }
        overlays.removeAll()
    }

    private func labelText(for group: GhosttyWindowGroup) -> String {
        if let label = windowLabels[group.id] {
            return label
        }

        for windowID in group.windowIDs {
            if let previousGroupID = windowIDToGroupID[windowID],
               let previousLabel = windowLabels[previousGroupID] {
                windowLabels[group.id] = previousLabel
                return previousLabel
            }
        }

        windowLabels[group.id] = group.title
        return group.title
    }

    private func installEventMonitors() {
        eventMonitorTokens.append(
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                if self?.editLabelIfNeeded(at: NSEvent.mouseLocation) == true {
                    return nil
                }

                return event
            } as Any
        )

        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            DispatchQueue.main.async {
                _ = self?.editLabelIfNeeded(at: NSEvent.mouseLocation)
            }
        }) {
            eventMonitorTokens.append(globalMonitor)
        }
    }

    private func editLabelIfNeeded(at point: NSPoint) -> Bool {
        guard !isEditing, pendingEditGroupID == nil else {
            return true
        }

        let candidates = overlays.values.filter { overlay in
            overlay.isVisible && overlay.frame.contains(point)
        }

        guard !candidates.isEmpty else {
            return false
        }

        let target = candidates.first { $0.groupID == lastActiveGroupID } ?? candidates[0]
        scheduleEditLabel(for: target.groupID, currentLabel: target.badgeView.text)
        return true
    }

    private func scheduleEditLabel(for groupID: WindowGroupID, currentLabel: String) {
        guard pendingEditGroupID == nil, !isEditing else {
            return
        }

        pendingEditGroupID = groupID
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.pendingEditGroupID = nil
            self.editLabel(for: groupID, currentLabel: currentLabel)
        }
    }

    private func editLabel(for groupID: WindowGroupID, currentLabel: String) {
        isEditing = true
        defer {
            isEditing = false
            activateGhostty()
            refresh()
        }

        NSApp.activate(ignoringOtherApps: true)

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = windowLabels[groupID] ?? currentLabel

        let alert = NSAlert()
        alert.messageText = "Edit Ghostty Label"
        alert.informativeText = "This label belongs to the Ghostty window, not the selected tab."
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        alert.window.level = .modalPanel

        input.selectText(nil)
        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            let label = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty {
                windowLabels[groupID] = "Ghostty"
            } else {
                windowLabels[groupID] = label
            }
        case .alertSecondButtonReturn:
            windowLabels[groupID] = "Ghostty"
        default:
            break
        }
    }

    private func isGhosttyFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.localizedName == "Ghostty"
    }

    private func isHelperFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private func activateGhostty() {
        NSWorkspace.shared.runningApplications
            .first { $0.localizedName == "Ghostty" }?
            .activate(options: [.activateIgnoringOtherApps])
    }

    private func assignStableIDs(to detectedGroups: [DetectedGhosttyWindowGroup]) -> [GhosttyWindowGroup] {
        var usedIDs = Set<WindowGroupID>()
        var groups: [GhosttyWindowGroup] = []

        for detectedGroup in detectedGroups {
            let groupID = bestExistingGroupID(for: detectedGroup, excluding: usedIDs) ?? newWindowGroupID()
            usedIDs.insert(groupID)
            groups.append(
                GhosttyWindowGroup(
                    id: groupID,
                    windowIDs: detectedGroup.windowIDs,
                    title: detectedGroup.title,
                    bounds: detectedGroup.bounds
                )
            )
        }

        knownBoundsByGroupID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.bounds) })
        knownWindowIDsByGroupID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.windowIDs) })
        return groups
    }

    private func bestExistingGroupID(
        for detectedGroup: DetectedGhosttyWindowGroup,
        excluding usedIDs: Set<WindowGroupID>
    ) -> WindowGroupID? {
        var bestMatch: (id: WindowGroupID, score: CGFloat)?

        for (groupID, previousBounds) in knownBoundsByGroupID where !usedIDs.contains(groupID) {
            let previousWindowIDs = knownWindowIDsByGroupID[groupID] ?? []
            let hasSharedWindowID = !previousWindowIDs.isDisjoint(with: detectedGroup.windowIDs)
            let frameScore = samePhysicalWindow(previousBounds, detectedGroup.bounds)
                ? CGFloat(250)
                : intersectionOverUnion(previousBounds, detectedGroup.bounds) * 100
            let idScore = hasSharedWindowID ? CGFloat(1000) : 0
            let score = frameScore + idScore

            if bestMatch == nil || score > bestMatch!.score {
                bestMatch = (groupID, score)
            }
        }

        guard let bestMatch, bestMatch.score >= 50 else {
            return nil
        }

        return bestMatch.id
    }

    private func newWindowGroupID() -> WindowGroupID {
        defer {
            nextWindowGroupNumber += 1
        }

        return "window-\(nextWindowGroupNumber)"
    }

    private func detectPhysicalWindows(_ windows: [GhosttyWindow]) -> [DetectedGhosttyWindowGroup] {
        var groupedWindows: [[GhosttyWindow]] = []

        for window in windows {
            if let index = groupedWindows.firstIndex(where: { existingGroup in
                guard let first = existingGroup.first else {
                    return false
                }

                return samePhysicalWindow(first.bounds, window.bounds)
            }) {
                groupedWindows[index].append(window)
            } else {
                groupedWindows.append([window])
            }
        }

        return groupedWindows.map { group in
            let ids = Set(group.map(\.id))
            let bounds = group.reduce(group[0].bounds) { partial, window in
                partial.union(window.bounds)
            }

            return DetectedGhosttyWindowGroup(
                windowIDs: ids,
                title: group[0].title,
                bounds: bounds
            )
        }
    }

    private func samePhysicalWindow(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 8 &&
            abs(lhs.minY - rhs.minY) <= 8 &&
            abs(lhs.width - rhs.width) <= 16 &&
            abs(lhs.height - rhs.height) <= 16
    }

    private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else {
            return 0
        }

        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        guard unionArea > 0 else {
            return 0
        }

        return intersectionArea / unionArea
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

    private func labelFrame(for window: GhosttyWindowGroup, label: String) -> NSRect {
        let size = badgeSize(for: label)
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
