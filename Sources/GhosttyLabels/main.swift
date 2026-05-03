import ApplicationServices
import Cocoa
import CoreGraphics

private typealias SplitID = String

private struct GhosttyWindow {
    let id: CGWindowID
    let title: String
    let bounds: CGRect
}

private struct DetectedSplit {
    let title: String
    let windowTitle: String
    let bounds: CGRect
    let windowBounds: CGRect
    let isFocused: Bool
}

private struct GhosttySplit {
    let id: SplitID
    let title: String
    let persistenceKey: String
    let bounds: CGRect
    let windowBounds: CGRect
    let isFocused: Bool
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
    var onKeyDown: ((NSEvent) -> Bool)?

    var text: String {
        didSet { needsDisplay = true }
    }

    var isActive: Bool = true {
        didSet { needsDisplay = true }
    }

    var isClickable: Bool = true {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    var isEditing: Bool = false {
        didSet { needsDisplay = true }
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

        if isEditing {
            let measured = (text as NSString).size(withAttributes: attributes)
            let visibleTextWidth = min(measured.width, textRect.width)
            let textStartX = textRect.midX - visibleTextWidth / 2
            let caretX = min(textStartX + visibleTextWidth + 2, textRect.maxX - 2)
            let caretRect = NSRect(x: caretX, y: bounds.midY - 8, width: 2, height: 16)
            NSColor.white.setFill()
            caretRect.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true {
            return
        }

        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        if isClickable {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}

private enum LabelEditResult {
    case save(String)
    case cancel
}

private final class LabelWindow: NSPanel {
    let badgeView: BadgeView
    var splitID: SplitID
    var onEdit: ((SplitID, String) -> Void)?
    var onMouseDown: ((NSPoint) -> Void)?
    private var editCompletion: ((LabelEditResult) -> Void)?
    private var editing = false
    private var isFinishingEdit = false

    var isEditing: Bool {
        editing
    }

    init(splitID: SplitID, text: String, frame: NSRect) {
        self.splitID = splitID
        self.badgeView = BadgeView(text: text)
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        level = .statusBar
        badgeView.onClick = { [weak self] in
            guard let self else { return }
            log("ghostty-labels: badge mouseDown split=\(self.splitID)")
            self.onEdit?(self.splitID, self.badgeView.text)
        }
        contentView = badgeView
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onEdit?(splitID, badgeView.text)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            onMouseDown?(NSEvent.mouseLocation)
        }

        super.sendEvent(event)
    }

    func beginEditing(currentText: String, onComplete: @escaping (LabelEditResult) -> Void) {
        if editing {
            focusEditor()
            return
        }

        isFinishingEdit = false
        editCompletion = onComplete
        editing = true
        badgeView.text = currentText
        badgeView.isEditing = true
        contentView = badgeView
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        focusEditor()
    }

    func focusEditor() {
        guard editing else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        let accepted = makeFirstResponder(badgeView)
        log("ghostty-labels: edit focus split=\(splitID) accepted=\(accepted) custom=true")
    }

    func finishEditingAndSave() {
        finishEditing(.save(badgeView.text))
    }

    func updateEditingText(_ text: String) {
        guard editing else {
            return
        }

        badgeView.text = text
    }

    private func cancelEditing() {
        finishEditing(.cancel)
    }

    private func finishEditing(_ result: LabelEditResult) {
        guard !isFinishingEdit else {
            return
        }

        isFinishingEdit = true
        editing = false
        badgeView.isEditing = false
        let completion = editCompletion
        editCompletion = nil
        contentView = badgeView
        completion?(result)
        isFinishingEdit = false
    }
}

private final class LabelController {
    private var overlays: [SplitID: LabelWindow] = [:]
    private var splitLabels: [SplitID: String] = [:]
    private var persistedLabels: [String: String] = LabelController.loadPersistedLabels()
    private var knownBoundsBySplitID: [SplitID: CGRect] = [:]
    private var knownWindowBoundsBySplitID: [SplitID: CGRect] = [:]
    private var persistenceKeyBySplitID: [SplitID: String] = [:]
    private var nextSplitNumber = 1
    private let position = LabelPosition.configured
    private let alwaysShow = ProcessInfo.processInfo.environment["GHOSTTY_LABEL_ALWAYS"] == "1"
    private var editingSplitID: SplitID?
    private var editingBuffer: String?
    private var pendingEditSplitID: SplitID?
    private var lastActiveSplitID: SplitID?
    private var lastActiveGhosttyWindowBounds: CGRect?
    private var timer: Timer?
    private var eventMonitorTokens: [Any] = []
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var warnedAboutAccessibility = false
    private var lastReportedSplitCount: Int?
    private var lastAXWindowErrorLogTime = Date.distantPast

    private var isEditing: Bool {
        editingSplitID != nil
    }

    func start() {
        installEventMonitors()
        if hasAccessibilityPermission() {
            installEventTap()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        refresh()
        log("ghostty-labels: bundle=\(Bundle.main.bundleIdentifier ?? "none") executable=\(Bundle.main.executablePath ?? "unknown")")
        log("ghostty-labels running. Click a split label to edit it. Stop with ctrl+c.")
    }

    private func refresh() {
        guard !isEditing else {
            return
        }

        if AXIsProcessTrusted(), eventTap == nil {
            installEventTap()
        }

        let ghosttyFrontmost = isGhosttyFrontmost()
        let helperFrontmost = isHelperFrontmost()
        guard alwaysShow || ghosttyFrontmost || helperFrontmost else {
            removeAllOverlays()
            return
        }

        let visibleWindows = visibleGhosttyWindows()
        let activeWindowBounds: CGRect?
        if ghosttyFrontmost {
            activeWindowBounds = visibleWindows.first?.bounds
            lastActiveGhosttyWindowBounds = activeWindowBounds
        } else {
            activeWindowBounds = lastActiveGhosttyWindowBounds
        }

        guard let activeWindowBounds else {
            removeAllOverlays()
            return
        }

        let detectedSplits = detectGhosttySplits(in: activeWindowBounds, visibleWindows: visibleWindows)
        if lastReportedSplitCount != detectedSplits.count {
            lastReportedSplitCount = detectedSplits.count
            log("ghostty-labels: detected \(detectedSplits.count) Ghostty split pane(s)")
        }

        let splits = assignStableIDs(to: detectedSplits)
        let liveIDs = Set(splits.map(\.id))

        for staleID in overlays.keys where !liveIDs.contains(staleID) {
            overlays[staleID]?.close()
            overlays.removeValue(forKey: staleID)
            persistenceKeyBySplitID.removeValue(forKey: staleID)
            if editingSplitID == staleID {
                editingSplitID = nil
            }
        }

        if ghosttyFrontmost {
            lastActiveSplitID = splits.first(where: \.isFocused)?.id ?? splits.first?.id
        }
        let activeSplitID = liveIDs.contains(lastActiveSplitID ?? "") ? lastActiveSplitID : splits.first?.id

        for split in splits {
            let label = labelText(for: split)
            let frame = labelFrame(for: split, label: label)
            let isActive = split.id == activeSplitID
            let acceptsMouse = split.id == activeSplitID

            if let overlay = overlays[split.id] {
                overlay.splitID = split.id
                if !overlay.isEditing {
                    overlay.badgeView.text = label
                }
                overlay.badgeView.isActive = isActive
                overlay.badgeView.isClickable = acceptsMouse
                overlay.alphaValue = 1
                overlay.ignoresMouseEvents = !acceptsMouse
                overlay.setFrame(frame, display: true)
            } else {
                let overlay = LabelWindow(splitID: split.id, text: label, frame: frame)
                overlay.badgeView.isActive = isActive
                overlay.badgeView.isClickable = acceptsMouse
                overlay.alphaValue = 1
                overlay.ignoresMouseEvents = !acceptsMouse
                overlay.onEdit = { [weak self] splitID, currentLabel in
                    self?.editActiveLabelIfNeeded(splitID: splitID, currentLabel: currentLabel)
                }
                overlay.onMouseDown = { [weak self] point in
                    _ = self?.handleLabelClick(at: point)
                }
                overlay.badgeView.onKeyDown = { [weak self] event in
                    self?.handleKeyDown(event) ?? false
                }
                overlays[split.id] = overlay
            }
        }

        for split in splits where split.id != activeSplitID {
            overlays[split.id]?.orderFrontRegardless()
        }

        if let activeSplitID {
            overlays[activeSplitID]?.orderFrontRegardless()
        }
    }

    private func removeAllOverlays() {
        for overlay in overlays.values {
            overlay.close()
        }
        overlays.removeAll()
    }

    private func labelText(for split: GhosttySplit) -> String {
        if let label = splitLabels[split.id] {
            return label
        }

        let label = persistedLabels[split.persistenceKey] ?? split.title
        splitLabels[split.id] = label
        return label
    }

    private func installEventMonitors() {
        eventMonitorTokens.append(
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                if self?.handleLabelClick(at: NSEvent.mouseLocation) == true {
                    return nil
                }

                return event
            } as Any
        )

        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            DispatchQueue.main.async {
                _ = self?.handleLabelClick(at: NSEvent.mouseLocation)
            }
        }) {
            eventMonitorTokens.append(globalMonitor)
        }
    }

    private func installEventTap() {
        guard eventTap == nil else {
            return
        }

        let eventMask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let controller = Unmanaged<LabelController>.fromOpaque(refcon).takeUnretainedValue()
                if type == .keyDown, controller.handleKeyDown(event) {
                    return nil
                }

                guard type == .leftMouseDown else {
                    return Unmanaged.passUnretained(event)
                }

                let point = controller.appKitPoint(fromQuartzPoint: event.location)
                if controller.handleLabelClick(at: point) {
                    return nil
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            log("ghostty-labels: failed to install mouse event tap")
            return
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            log("ghostty-labels: failed to create mouse event tap run loop source")
            return
        }

        eventTap = tap
        eventTapRunLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("ghostty-labels: mouse event tap installed")
    }

    private func handleLabelClick(at point: NSPoint) -> Bool {
        if let editingSplitID, let editingOverlay = overlays[editingSplitID] {
            if editingOverlay.frame.contains(point) {
                editingOverlay.focusEditor()
                return true
            }

            editingOverlay.finishEditingAndSave()
            return false
        }

        guard pendingEditSplitID == nil,
              let activeSplitID = lastActiveSplitID,
              let activeOverlay = overlays[activeSplitID],
              activeOverlay.isVisible,
              activeOverlay.frame.contains(point)
        else {
            return false
        }

        guard activeOverlay.badgeView.isActive else {
            return false
        }

        log("ghostty-labels: active label click at \(Int(point.x)),\(Int(point.y)) split=\(activeOverlay.splitID)")
        scheduleEditLabel(for: activeOverlay.splitID, currentLabel: activeOverlay.badgeView.text)
        return true
    }

    private func editActiveLabelIfNeeded(splitID: SplitID, currentLabel: String) {
        guard splitID == lastActiveSplitID else {
            return
        }

        scheduleEditLabel(for: splitID, currentLabel: currentLabel)
    }

    private func scheduleEditLabel(for splitID: SplitID, currentLabel: String) {
        guard pendingEditSplitID == nil, editingSplitID == nil else {
            return
        }

        pendingEditSplitID = splitID
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.pendingEditSplitID = nil
            self.editLabel(for: splitID, currentLabel: currentLabel)
        }
    }

    private func editLabel(for splitID: SplitID, currentLabel: String) {
        guard let overlay = overlays[splitID] else {
            return
        }

        let initialText = splitLabels[splitID] ?? currentLabel
        editingSplitID = splitID
        editingBuffer = initialText
        lastActiveSplitID = splitID

        overlay.beginEditing(currentText: initialText) { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case .save(let rawLabel):
                self.saveLabel(rawLabel, for: splitID)
            case .cancel:
                break
            }

            self.editingSplitID = nil
            self.editingBuffer = nil
            self.refresh()
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        guard let editingSplitID,
              let overlay = overlays[editingSplitID]
        else {
            return false
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 53 {
            overlay.finishEditingAndSave()
            return true
        }

        if keyCode == 36 || keyCode == 76 || keyCode == 48 {
            overlay.finishEditingAndSave()
            return true
        }

        var buffer = editingBuffer ?? overlay.badgeView.text
        if keyCode == 51 || keyCode == 117 {
            if !buffer.isEmpty {
                buffer.removeLast()
            }
        } else {
            guard !event.flags.contains(.maskCommand),
                  !event.flags.contains(.maskControl)
            else {
                return true
            }

            let characters = unicodeString(from: event)
            guard !characters.isEmpty else {
                return true
            }

            buffer += characters
        }

        updateEditingText(buffer, for: editingSplitID, overlay: overlay)
        return true
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let editingSplitID,
              let overlay = overlays[editingSplitID]
        else {
            return false
        }

        switch event.keyCode {
        case 53:
            overlay.finishEditingAndSave()
            return true
        case 36, 76, 48:
            overlay.finishEditingAndSave()
            return true
        case 51, 117:
            var buffer = editingBuffer ?? overlay.badgeView.text
            if !buffer.isEmpty {
                buffer.removeLast()
            }
            updateEditingText(buffer, for: editingSplitID, overlay: overlay)
            return true
        default:
            guard !event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.control)
            else {
                return true
            }

            guard let characters = event.characters, !characters.isEmpty else {
                return true
            }

            let buffer = (editingBuffer ?? overlay.badgeView.text) + characters
            updateEditingText(buffer, for: editingSplitID, overlay: overlay)
            return true
        }
    }

    private func updateEditingText(_ buffer: String, for splitID: SplitID, overlay: LabelWindow) {
        editingBuffer = buffer
        overlay.updateEditingText(buffer)
        updateOverlayFrame(overlay, for: splitID, label: buffer)
        saveLabel(buffer, for: splitID)
        log("ghostty-labels: edit text split=\(splitID) length=\(buffer.count)")
    }

    private func updateOverlayFrame(_ overlay: LabelWindow, for splitID: SplitID, label: String) {
        guard let splitBounds = knownBoundsBySplitID[splitID] else {
            return
        }

        overlay.setFrame(labelFrame(forSplitBounds: splitBounds, label: label), display: true)
    }

    private func unicodeString(from event: CGEvent) -> String {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(
            maxStringLength: chars.count,
            actualStringLength: &length,
            unicodeString: &chars
        )

        guard length > 0 else {
            return ""
        }

        return String(utf16CodeUnits: chars, count: length)
    }

    private func saveLabel(_ rawLabel: String, for splitID: SplitID) {
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        splitLabels[splitID] = label.isEmpty ? "Ghostty" : label

        guard let persistenceKey = persistenceKeyBySplitID[splitID] else {
            return
        }

        if label.isEmpty || label == "Ghostty" {
            persistedLabels.removeValue(forKey: persistenceKey)
        } else {
            persistedLabels[persistenceKey] = label
        }
        savePersistedLabels()
    }

    private static func labelsStoreURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Ghostty Labels", isDirectory: true)
            .appendingPathComponent("labels.json")
    }

    private static func loadPersistedLabels() -> [String: String] {
        guard let url = labelsStoreURL(),
              let data = try? Data(contentsOf: url)
        else {
            return [:]
        }

        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            log("ghostty-labels: failed to load labels from \(url.path): \(error)")
            return [:]
        }
    }

    private func savePersistedLabels() {
        guard let url = Self.labelsStoreURL() else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(persistedLabels)
            try data.write(to: url, options: .atomic)
        } catch {
            log("ghostty-labels: failed to save labels to \(url.path): \(error)")
        }
    }

    private func detectGhosttySplits(in activeWindowBounds: CGRect, visibleWindows: [GhosttyWindow]) -> [DetectedSplit] {
        _ = hasAccessibilityPermission()

        guard let app = ghosttyApplication() else {
            return []
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let focusedFrame = axFrame(axElement(axApp, kAXFocusedUIElementAttribute))
        let axWindowResult = axAttributeResult(axApp, kAXWindowsAttribute)
        let axWindows = axWindowResult.value as? [AXUIElement] ?? []
        if (axWindowResult.error != .success || axWindows.isEmpty) &&
            Date().timeIntervalSince(lastAXWindowErrorLogTime) > 5 {
            lastAXWindowErrorLogTime = Date()
            log("ghostty-labels: ax windows error=\(axWindowResult.error.rawValue) trusted=\(AXIsProcessTrusted()) visibleWindows=\(visibleWindows.count) axWindows=\(axWindows.count)")
        }

        return axWindows.flatMap { axWindow -> [DetectedSplit] in
            guard let windowFrame = axFrame(axWindow),
                  let visibleWindow = visibleWindows.first(where: { samePhysicalWindow($0.bounds, windowFrame) }),
                  samePhysicalWindow(activeWindowBounds, windowFrame) else {
                return []
            }

            let scrollFrames = uniqueFrames(terminalScrollAreaFrames(in: axWindow, windowFrame: windowFrame))
            if scrollFrames.isEmpty {
                return []
            }

            return scrollFrames.map { frame in
                DetectedSplit(
                    title: "Ghostty",
                    windowTitle: visibleWindow.title,
                    bounds: frame,
                    windowBounds: windowFrame,
                    isFocused: focusedFrame.map { samePhysicalWindow($0, frame) || intersectionOverUnion($0, frame) > 0.8 } ?? false
                )
            }
        }
    }

    private func terminalScrollAreaFrames(in root: AXUIElement, windowFrame: CGRect) -> [CGRect] {
        var frames: [CGRect] = []

        func walk(_ element: AXUIElement) {
            let role = axString(element, kAXRoleAttribute)
            if role == "AXScrollArea",
               let frame = axFrame(element),
               frame.width >= 120,
               frame.height >= 80,
               windowFrame.intersects(frame) {
                frames.append(frame)
            }

            for child in axElements(element, kAXChildrenAttribute) {
                walk(child)
            }
        }

        walk(root)
        return frames
    }

    private func assignStableIDs(to detectedSplits: [DetectedSplit]) -> [GhosttySplit] {
        var usedIDs = Set<SplitID>()
        var splits: [GhosttySplit] = []

        for detectedSplit in detectedSplits {
            let splitID = bestExistingSplitID(for: detectedSplit, excluding: usedIDs) ?? newSplitID()
            usedIDs.insert(splitID)
            splits.append(
                GhosttySplit(
                    id: splitID,
                    title: detectedSplit.title,
                    persistenceKey: persistenceKey(for: detectedSplit),
                    bounds: detectedSplit.bounds,
                    windowBounds: detectedSplit.windowBounds,
                    isFocused: detectedSplit.isFocused
                )
            )
        }

        for split in splits {
            knownBoundsBySplitID[split.id] = split.bounds
            knownWindowBoundsBySplitID[split.id] = split.windowBounds
            persistenceKeyBySplitID[split.id] = split.persistenceKey
        }

        return splits
    }

    private func persistenceKey(for split: DetectedSplit) -> String {
        let title = split.windowTitle
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let windowTitle = title.isEmpty ? "Ghostty" : title
        let window = split.windowBounds

        guard window.width > 0, window.height > 0 else {
            return "\(windowTitle)|absolute|\(rounded(split.bounds.minX))|\(rounded(split.bounds.minY))|\(rounded(split.bounds.width))|\(rounded(split.bounds.height))"
        }

        let relativeX = (split.bounds.minX - window.minX) / window.width
        let relativeY = (split.bounds.minY - window.minY) / window.height
        let relativeWidth = split.bounds.width / window.width
        let relativeHeight = split.bounds.height / window.height
        return "\(windowTitle)|relative|\(rounded(relativeX))|\(rounded(relativeY))|\(rounded(relativeWidth))|\(rounded(relativeHeight))"
    }

    private func rounded(_ value: CGFloat) -> String {
        String(format: "%.3f", Double(value))
    }

    private func bestExistingSplitID(for detectedSplit: DetectedSplit, excluding usedIDs: Set<SplitID>) -> SplitID? {
        var bestMatch: (id: SplitID, score: CGFloat)?

        for (splitID, previousBounds) in knownBoundsBySplitID where !usedIDs.contains(splitID) {
            let previousWindowBounds = knownWindowBoundsBySplitID[splitID] ?? .null
            let sameWindowScore = samePhysicalWindow(previousWindowBounds, detectedSplit.windowBounds) ? CGFloat(600) : 0
            let windowOverlapScore = intersectionOverUnion(previousWindowBounds, detectedSplit.windowBounds) * 300
            let splitOverlapScore = intersectionOverUnion(previousBounds, detectedSplit.bounds) * 1000
            let splitFrameScore = samePhysicalWindow(previousBounds, detectedSplit.bounds) ? CGFloat(500) : 0
            let score = sameWindowScore + windowOverlapScore + splitOverlapScore + splitFrameScore

            if bestMatch == nil || score > bestMatch!.score {
                bestMatch = (splitID, score)
            }
        }

        guard let bestMatch, bestMatch.score >= 250 else {
            return nil
        }

        return bestMatch.id
    }

    private func newSplitID() -> SplitID {
        defer { nextSplitNumber += 1 }
        return "split-\(nextSplitNumber)"
    }

    private func isGhosttyFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.localizedName == "Ghostty"
    }

    private func isHelperFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private func activateGhostty() {
        ghosttyApplication()?.activate(options: [.activateIgnoringOtherApps])
    }

    private func ghosttyApplication() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.mitchellh.ghostty" || $0.localizedName == "Ghostty"
        }
    }

    private func hasAccessibilityPermission() -> Bool {
        guard !AXIsProcessTrusted() else {
            return true
        }

        if !warnedAboutAccessibility {
            warnedAboutAccessibility = true
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            log("ghostty-labels: Accessibility permission is required for split-level labels. Grant it to ghostty-labels, then restart this helper.")
        }

        return false
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

    private func labelFrame(for split: GhosttySplit, label: String) -> NSRect {
        labelFrame(forSplitBounds: split.bounds, label: label)
    }

    private func labelFrame(forSplitBounds splitBounds: CGRect, label: String) -> NSRect {
        let size = badgeSize(for: label)
        let x: CGFloat

        switch position {
        case .topLeft:
            x = splitBounds.minX + 18
        case .topCenter:
            x = splitBounds.midX - size.width / 2
        case .topRight:
            x = splitBounds.maxX - size.width - 18
        }

        let y = appKitY(forTopEdgeOf: splitBounds) - size.height - 12
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

    private func appKitPoint(fromQuartzPoint point: CGPoint) -> NSPoint {
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }

            let displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
            guard displayBounds.contains(point) else {
                continue
            }

            return NSPoint(
                x: screen.frame.minX + point.x - displayBounds.minX,
                y: screen.frame.maxY - (point.y - displayBounds.minY)
            )
        }

        let maxY = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        return NSPoint(x: point.x, y: maxY - point.y)
    }
}

private func axAttribute(_ element: AXUIElement?, _ attribute: String) -> AnyObject? {
    axAttributeResult(element, attribute).value
}

private func axAttributeResult(_ element: AXUIElement?, _ attribute: String) -> (value: AnyObject?, error: AXError) {
    guard let element else {
        return (nil, .failure)
    }

    var value: AnyObject?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return (error == .success ? value : nil, error)
}

private func axElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
    axAttribute(element, attribute) as? [AXUIElement] ?? []
}

private func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let rawElement = axAttribute(element, attribute),
          CFGetTypeID(rawElement) == AXUIElementGetTypeID()
    else {
        return nil
    }

    return (rawElement as! AXUIElement)
}

private func axString(_ element: AXUIElement, _ attribute: String) -> String {
    axAttribute(element, attribute).map { String(describing: $0) } ?? ""
}

private func axFrame(_ element: AXUIElement?) -> CGRect? {
    guard let element,
          let rawPosition = axAttribute(element, kAXPositionAttribute),
          let rawSize = axAttribute(element, kAXSizeAttribute),
          CFGetTypeID(rawPosition) == AXValueGetTypeID(),
          CFGetTypeID(rawSize) == AXValueGetTypeID()
    else {
        return nil
    }

    let positionValue = rawPosition as! AXValue
    let sizeValue = rawSize as! AXValue
    var point = CGPoint.zero
    var size = CGSize.zero
    guard
        AXValueGetValue(positionValue, .cgPoint, &point),
        AXValueGetValue(sizeValue, .cgSize, &size)
    else {
        return nil
    }

    return CGRect(origin: point, size: size)
}

private func uniqueFrames(_ frames: [CGRect]) -> [CGRect] {
    var result: [CGRect] = []

    for frame in frames {
        if !result.contains(where: { samePhysicalWindow($0, frame) }) {
            result.append(frame)
        }
    }

    return result
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

private func log(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
        let logURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/ghostty-labels-debug.log")
        if FileManager.default.fileExists(atPath: logURL.path),
           let file = try? FileHandle(forWritingTo: logURL) {
            defer { try? file.close() }
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: data)
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
private let controller = LabelController()
controller.start()
RunLoop.main.run()
