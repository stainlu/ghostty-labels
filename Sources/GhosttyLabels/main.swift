import ApplicationServices
import Cocoa
import CoreGraphics

private typealias SplitID = String
private let ghosttyLabelDebugLogging = ProcessInfo.processInfo.environment["GHOSTTY_LABEL_DEBUG"] == "1"
private let ghosttyLabelDebugFileLogging = ProcessInfo.processInfo.environment["GHOSTTY_LABEL_DEBUG_FILE"] == "1"

private struct GhosttyWindow {
    let id: CGWindowID
    let title: String
    let bounds: CGRect
}

private struct ActiveGhosttyWindow {
    let title: String
    let persistenceName: String
    let legacyPersistenceNames: [String]
    let bounds: CGRect
    let axWindow: AXUIElement
}

private struct GhosttyScriptContext {
    let signature: String
    let windowID: String
    let tabID: String
    let terminalIDs: [String]
}

private struct DetectedSplit {
    let title: String
    let windowTitle: String
    let windowPersistenceName: String
    let windowLegacyPersistenceNames: [String]
    let terminalID: String?
    let bounds: CGRect
    let windowBounds: CGRect
    let isFocused: Bool
}

private struct GhosttySplit {
    let id: SplitID
    let title: String
    let persistenceKey: String
    let legacyPersistenceKeys: [String]
    let bounds: CGRect
    let windowBounds: CGRect
    let isFocused: Bool
}

private struct ParsedRelativePersistenceKey {
    let windowName: String
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        level = .statusBar
        badgeView.onClick = { [weak self] in
            guard let self else { return }
            debugLog("ghostty-labels: badge mouseDown split=\(self.splitID)")
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
        debugLog("ghostty-labels: edit focus split=\(splitID) accepted=\(accepted) custom=true")
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
    private var persistedLabels: [String: String] = LabelController.loadPersistedLabels()
    private var knownBoundsBySplitID: [SplitID: CGRect] = [:]
    private var knownWindowBoundsBySplitID: [SplitID: CGRect] = [:]
    private var knownRelativeBoundsBySplitID: [SplitID: CGRect] = [:]
    private var persistenceKeyBySplitID: [SplitID: String] = [:]
    private var titleAliasesByWindowName: [String: Set<String>] = [:]
    private var nextSplitNumber = 1
    private let position = LabelPosition.configured
    private let alwaysShow = ProcessInfo.processInfo.environment["GHOSTTY_LABEL_ALWAYS"] == "1"
    private var editingSplitID: SplitID?
    private var editingBuffer: String?
    private var pendingEditSplitID: SplitID?
    private var cachedGhosttyApplication: NSRunningApplication?
    private var lastActiveSplitID: SplitID?
    private var lastActiveGhosttyWindow: ActiveGhosttyWindow?
    private var trackedAXWindow: AXUIElement?
    private var trackedWindowPersistenceName: String?
    private var scriptContext: GhosttyScriptContext?
    private var scriptContextLoadStartedAt = Date.distantPast
    private var scriptContextLogTime = Date.distantPast
    private var scriptContextGeneration = 0
    private var scriptContextRetryAfterBySignature: [String: Date] = [:]
    private var isLoadingScriptContext = false
    private var pendingLabelsSave: DispatchWorkItem?
    private var timer: Timer?
    private var eventMonitorTokens: [Any] = []
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private let debugLogging = ghosttyLabelDebugLogging
    private var warnedAboutAccessibility = false
    private var pendingRefresh = false
    private var lastReportedSplitCountsByWindow: [String: Int] = [:]
    private var lastAXWindowErrorLogTime = Date.distantPast
    private var lastEventTapHealthCheckAt = Date.distantPast
    private var lastOverlayOrderRefreshAt = Date.distantPast
    private var lastOrderedActiveSplitID: SplitID?

    private var isEditing: Bool {
        editingSplitID != nil
    }

    func start() {
        installEventMonitors()
        if hasAccessibilityPermission() {
            installEventTap()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        refresh()
        log("ghostty-labels: bundle=\(Bundle.main.bundleIdentifier ?? "none") executable=\(Bundle.main.executablePath ?? "unknown")")
        log("ghostty-labels running. Click a split label to edit it. Stop with ctrl+c.")
    }

    private func refresh() {
        pendingRefresh = false
        guard !isEditing else {
            return
        }

        let now = Date()
        if AXIsProcessTrusted() {
            if eventTap == nil {
                installEventTap()
            } else if now.timeIntervalSince(lastEventTapHealthCheckAt) >= 1 {
                lastEventTapHealthCheckAt = now
                ensureEventTapEnabled()
            }
        }

        let ghosttyFrontmost = isGhosttyFrontmost()
        let helperFrontmost = isHelperFrontmost()
        guard alwaysShow || ghosttyFrontmost || helperFrontmost else {
            removeAllOverlays()
            return
        }

        let activeWindow = activeGhosttyWindow() ?? lastActiveGhosttyWindow
        if ghosttyFrontmost || helperFrontmost {
            lastActiveGhosttyWindow = activeWindow
        }

        guard let activeWindow else {
            removeAllOverlays()
            return
        }
        rememberWindowTitle(activeWindow)
        resetSplitTrackingIfNeeded(for: activeWindow)

        let detectedSplits = detectGhosttySplits(in: activeWindow)
        if lastReportedSplitCountsByWindow[activeWindow.persistenceName] != detectedSplits.count {
            lastReportedSplitCountsByWindow[activeWindow.persistenceName] = detectedSplits.count
            debugLog("ghostty-labels: detected \(detectedSplits.count) Ghostty split pane(s) in window=\(activeWindow.title)")
        }

        let splits = assignStableIDs(to: detectedSplits)
        let liveIDs = Set(splits.map(\.id))
        var needsOverlayOrdering = false

        for staleID in overlays.keys where !liveIDs.contains(staleID) {
            overlays[staleID]?.close()
            overlays.removeValue(forKey: staleID)
            knownBoundsBySplitID.removeValue(forKey: staleID)
            knownWindowBoundsBySplitID.removeValue(forKey: staleID)
            knownRelativeBoundsBySplitID.removeValue(forKey: staleID)
            persistenceKeyBySplitID.removeValue(forKey: staleID)
            if editingSplitID == staleID {
                editingSplitID = nil
            }
            needsOverlayOrdering = true
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
                if !overlay.isEditing, overlay.badgeView.text != label {
                    overlay.badgeView.text = label
                }
                if overlay.badgeView.isActive != isActive {
                    overlay.badgeView.isActive = isActive
                    needsOverlayOrdering = true
                }
                if overlay.badgeView.isClickable != acceptsMouse {
                    overlay.badgeView.isClickable = acceptsMouse
                }
                if overlay.alphaValue != 1 {
                    overlay.alphaValue = 1
                }
                let ignoresMouseEvents = !acceptsMouse
                if overlay.ignoresMouseEvents != ignoresMouseEvents {
                    overlay.ignoresMouseEvents = ignoresMouseEvents
                }
                if !sameOverlayFrame(overlay.frame, frame) {
                    overlay.setFrame(frame, display: true)
                    needsOverlayOrdering = true
                }
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
                needsOverlayOrdering = true
            }
        }

        let activeOrderChanged = activeSplitID != lastOrderedActiveSplitID
        let shouldRefreshZOrder = now.timeIntervalSince(lastOverlayOrderRefreshAt) >= 2
        if needsOverlayOrdering || activeOrderChanged || shouldRefreshZOrder {
            for split in splits where split.id != activeSplitID {
                overlays[split.id]?.orderFrontRegardless()
            }

            if let activeSplitID {
                overlays[activeSplitID]?.orderFrontRegardless()
            }
            lastOverlayOrderRefreshAt = now
            lastOrderedActiveSplitID = activeSplitID
        }
    }

    private func removeAllOverlays() {
        for overlay in overlays.values {
            overlay.close()
        }
        overlays.removeAll()
        lastOrderedActiveSplitID = nil
    }

    private func resetSplitTrackingIfNeeded(for activeWindow: ActiveGhosttyWindow) {
        let activeWindowNames = Set([activeWindow.persistenceName] + activeWindow.legacyPersistenceNames)
        let sameTrackedWindow = trackedAXWindow.map { sameAXElement($0, activeWindow.axWindow) } == true ||
            trackedWindowPersistenceName.map { activeWindowNames.contains($0) } == true

        if trackedAXWindow != nil,
           !sameTrackedWindow {
            removeAllOverlays()
            knownBoundsBySplitID.removeAll()
            knownWindowBoundsBySplitID.removeAll()
            knownRelativeBoundsBySplitID.removeAll()
            persistenceKeyBySplitID.removeAll()
            lastActiveSplitID = nil
            nextSplitNumber = 1
            scriptContext = nil
            scriptContextLoadStartedAt = Date.distantPast
            scriptContextRetryAfterBySignature.removeAll()
            scriptContextGeneration += 1
        }

        trackedAXWindow = activeWindow.axWindow
        trackedWindowPersistenceName = activeWindow.persistenceName
    }

    private func labelText(for split: GhosttySplit) -> String {
        if let label = persistedLabels[split.persistenceKey] {
            return label
        }

        for legacyKey in split.legacyPersistenceKeys {
            if let label = persistedLabels[legacyKey] {
                persistedLabels[split.persistenceKey] = label
                schedulePersistedLabelsSave()
                return label
            }
        }

        if let label = approximateLegacyLabel(for: split) {
            return label
        }

        return split.title
    }

    private func approximateLegacyLabel(for split: GhosttySplit) -> String? {
        let targetBounds = relativeBounds(for: split.bounds, in: split.windowBounds)
        let targetNames = Set(([split.persistenceKey] + split.legacyPersistenceKeys)
            .compactMap(parseRelativePersistenceKey)
            .map(\.windowName))
        guard !targetNames.isEmpty else {
            return nil
        }

        var bestMatch: (key: String, label: String, score: CGFloat)?
        for (key, label) in persistedLabels {
            guard let parsed = parseRelativePersistenceKey(key),
                  targetNames.contains(parsed.windowName)
            else {
                continue
            }

            let score = intersectionOverUnion(parsed.bounds, targetBounds)
            if bestMatch == nil || score > bestMatch!.score {
                bestMatch = (key, label, score)
            }
        }

        guard let bestMatch,
              bestMatch.score >= 0.65
        else {
            return nil
        }

        persistedLabels[split.persistenceKey] = bestMatch.label
        schedulePersistedLabelsSave()
        debugLog("ghostty-labels: migrated approximate label key=\(bestMatch.key) score=\(rounded(bestMatch.score))")
        return bestMatch.label
    }

    private func refreshScriptContextIfNeeded(for activeWindow: ActiveGhosttyWindow, splitCount: Int) {
        guard splitCount > 0 else {
            return
        }

        let signature = scriptContextSignature(for: activeWindow, splitCount: splitCount)
        if scriptContext?.signature == signature,
           scriptContext?.terminalIDs.count == splitCount {
            return
        }

        let now = Date()
        if let retryAfter = scriptContextRetryAfterBySignature[signature],
           retryAfter > now {
            return
        }

        guard !isLoadingScriptContext,
              now.timeIntervalSince(scriptContextLoadStartedAt) >= 1.5
        else {
            return
        }

        isLoadingScriptContext = true
        scriptContextLoadStartedAt = now
        let generation = scriptContextGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.loadGhosttyScriptContext(signature: signature)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoadingScriptContext = false
                guard generation == self.scriptContextGeneration else {
                    return
                }
                self.scriptContext = result.context
                if let error = result.error,
                   Date().timeIntervalSince(self.scriptContextLogTime) > 10 {
                    self.scriptContextLogTime = Date()
                    log("ghostty-labels: Ghostty scripting IDs unavailable: \(error)")
                }
                if let context = result.context,
                   context.terminalIDs.count != splitCount {
                    self.scriptContextRetryAfterBySignature[signature] = Date().addingTimeInterval(15)
                } else {
                    self.scriptContextRetryAfterBySignature.removeValue(forKey: signature)
                }
                if let context = result.context,
                   context.terminalIDs.count == splitCount,
                   !self.isEditing {
                    self.refresh()
                }
            }
        }
    }

    private func scriptContextSignature(for activeWindow: ActiveGhosttyWindow, splitCount: Int) -> String {
        "\(activeWindow.persistenceName)|splits:\(splitCount)"
    }

    private static func loadGhosttyScriptContext(signature: String) -> (context: GhosttyScriptContext?, error: String?) {
        let source = """
        set AppleScript's text item delimiters to linefeed
        tell application "Ghostty"
            set w to front window
            set t to selected tab of w
            set terminalIds to id of terminals of t
            return (id of w) & linefeed & (id of t) & linefeed & (terminalIds as text)
        end tell
        """

        guard let script = NSAppleScript(source: source) else {
            return (nil, "failed to create AppleScript")
        }

        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            return (nil, String(describing: errorInfo))
        }

        let output = descriptor.stringValue ?? ""
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 3 else {
            return (nil, "expected window, tab, and terminal IDs; got \(lines.count) line(s)")
        }

        return (
            GhosttyScriptContext(
                signature: signature,
                windowID: lines[0],
                tabID: lines[1],
                terminalIDs: Array(lines.dropFirst(2))
            ),
            nil
        )
    }

    private func installEventMonitors() {
        eventMonitorTokens.append(
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                if self?.handleLabelClick(at: NSEvent.mouseLocation) == true {
                    return nil
                }

                self?.scheduleRefresh(after: 0.08)
                return event
            } as Any
        )

        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            DispatchQueue.main.async {
                if self?.handleLabelClick(at: NSEvent.mouseLocation) != true {
                    self?.scheduleRefresh(after: 0.08)
                }
            }
        }) {
            eventMonitorTokens.append(globalMonitor)
        }

        let activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.mitchellh.ghostty" || app.localizedName == "Ghostty"
            else {
                return
            }

            self?.scheduleRefresh(after: 0.05)
        }
        eventMonitorTokens.append(activationObserver)
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
                if type == .tapDisabledByTimeout {
                    controller.reenableEventTap(reason: "timeout")
                    return Unmanaged.passUnretained(event)
                }

                if type == .tapDisabledByUserInput {
                    controller.reenableEventTap(reason: "user-input")
                    return Unmanaged.passUnretained(event)
                }

                if type == .keyDown, controller.handleKeyDown(event) {
                    return nil
                }

                guard type == .leftMouseDown else {
                    return Unmanaged.passUnretained(event)
                }

                let point = event.unflippedLocation
                if controller.handleLabelClick(at: point) {
                    return nil
                }

                if controller.isGhosttyFrontmost() {
                    controller.scheduleRefresh(after: 0.08)
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

    private func ensureEventTapEnabled() {
        guard let eventTap,
              !CGEvent.tapIsEnabled(tap: eventTap)
        else {
            return
        }

        CGEvent.tapEnable(tap: eventTap, enable: true)
        debugLog("ghostty-labels: mouse event tap re-enabled")
    }

    private func reenableEventTap(reason: String) {
        guard let eventTap else {
            return
        }

        CGEvent.tapEnable(tap: eventTap, enable: true)
        debugLog("ghostty-labels: mouse event tap re-enabled after \(reason)")
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        guard !pendingRefresh, !isEditing else {
            return
        }

        pendingRefresh = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.refresh()
        }
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

        guard pendingEditSplitID == nil
        else {
            return false
        }

        guard let activeOverlay = overlays.values.first(where: { overlay in
            overlay.isVisible &&
                !overlay.ignoresMouseEvents &&
                overlay.badgeView.isActive &&
                overlay.frame.contains(point)
        }) else {
            return false
        }

        lastActiveSplitID = activeOverlay.splitID
        debugLog("ghostty-labels: active label click at \(Int(point.x)),\(Int(point.y)) split=\(activeOverlay.splitID)")
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

        let initialText = persistenceKeyBySplitID[splitID].flatMap { persistedLabels[$0] } ?? currentLabel
        editingSplitID = splitID
        editingBuffer = initialText
        lastActiveSplitID = splitID

        overlay.beginEditing(currentText: initialText) { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case .save(let rawLabel):
                self.saveLabel(rawLabel, for: splitID, flush: true)
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
        if debugLogging {
            log("ghostty-labels: edit text split=\(splitID) length=\(buffer.count)")
        }
    }

    private func updateOverlayFrame(_ overlay: LabelWindow, for splitID: SplitID, label: String) {
        guard let splitBounds = knownBoundsBySplitID[splitID] else {
            return
        }

        let frame = labelFrame(forSplitBounds: splitBounds, label: label)
        if !sameOverlayFrame(overlay.frame, frame) {
            overlay.setFrame(frame, display: true)
        }
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

    private func saveLabel(_ rawLabel: String, for splitID: SplitID, flush: Bool = false) {
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let persistenceKey = persistenceKeyBySplitID[splitID] else {
            return
        }

        if label.isEmpty || label == "Ghostty" {
            persistedLabels.removeValue(forKey: persistenceKey)
        } else {
            persistedLabels[persistenceKey] = label
        }

        if flush {
            savePersistedLabels()
        } else {
            schedulePersistedLabelsSave()
        }
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
        pendingLabelsSave?.cancel()
        pendingLabelsSave = nil

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

    private func schedulePersistedLabelsSave() {
        pendingLabelsSave?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.savePersistedLabels()
        }
        pendingLabelsSave = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func activeGhosttyWindow() -> ActiveGhosttyWindow? {
        guard let app = ghosttyApplication() else {
            return nil
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let focusedWindow = axElement(axApp, kAXFocusedWindowAttribute),
              let focusedFrame = axFrame(focusedWindow)
        else {
            return nil
        }

        let visibleWindows = visibleGhosttyWindows()
        let focusedTitle = normalizedTitle(axString(focusedWindow, kAXTitleAttribute))
        let visibleWindow = matchingVisibleWindow(
            forFrame: focusedFrame,
            title: focusedTitle,
            in: visibleWindows
        )
        let visibleTitle = visibleWindow.map { normalizedTitle($0.title) } ?? ""
        let title = firstMeaningfulTitle(focusedTitle, visibleTitle) ?? "Ghostty"
        var persistenceName = persistenceWindowName(
            forTitle: title,
            visibleWindow: visibleWindow,
            visibleWindows: visibleWindows,
            app: app,
            frame: focusedFrame
        )
        var legacyPersistenceNames: [String] = []
        if let previousWindow = lastActiveGhosttyWindow,
           sameAXElement(previousWindow.axWindow, focusedWindow) {
            if visibleWindow == nil {
                legacyPersistenceNames.append(persistenceName)
                persistenceName = previousWindow.persistenceName
            } else if previousWindow.persistenceName != persistenceName {
                legacyPersistenceNames.append(previousWindow.persistenceName)
            }
            legacyPersistenceNames.append(contentsOf: previousWindow.legacyPersistenceNames)
        }
        legacyPersistenceNames = uniqueStrings(legacyPersistenceNames.filter { $0 != persistenceName })

        return ActiveGhosttyWindow(
            title: title,
            persistenceName: persistenceName,
            legacyPersistenceNames: legacyPersistenceNames,
            bounds: focusedFrame,
            axWindow: focusedWindow
        )
    }

    private func detectGhosttySplits(in activeWindow: ActiveGhosttyWindow) -> [DetectedSplit] {
        _ = hasAccessibilityPermission()

        guard let app = ghosttyApplication() else {
            return []
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let focusedFrame = axFrame(axElement(axApp, kAXFocusedUIElementAttribute))
        let scrollFrames = uniqueFrames(terminalScrollAreaFrames(in: activeWindow.axWindow, windowFrame: activeWindow.bounds))
        if scrollFrames.isEmpty,
           Date().timeIntervalSince(lastAXWindowErrorLogTime) > 5 {
            lastAXWindowErrorLogTime = Date()
            log("ghostty-labels: active window has no scroll areas trusted=\(AXIsProcessTrusted()) window=\(activeWindow.title)")
        }

        let scriptSignature = scriptContextSignature(for: activeWindow, splitCount: scrollFrames.count)
        refreshScriptContextIfNeeded(for: activeWindow, splitCount: scrollFrames.count)
        let terminalIDs: [String]? = {
            guard let scriptContext,
                  scriptContext.signature == scriptSignature,
                  scriptContext.terminalIDs.count == scrollFrames.count
            else {
                return nil
            }

            return scriptContext.terminalIDs
        }()

        if let scriptContext,
           scriptContext.signature == scriptSignature,
           scriptContext.terminalIDs.count != scrollFrames.count,
           debugLogging,
           Date().timeIntervalSince(scriptContextLogTime) > 30 {
            scriptContextLogTime = Date()
            log("ghostty-labels: Ghostty scripting split count mismatch ids=\(scriptContext.terminalIDs.count) ax=\(scrollFrames.count) windowID=\(scriptContext.windowID) tabID=\(scriptContext.tabID)")
        }

        return scrollFrames.enumerated().map { index, frame in
            DetectedSplit(
                title: "Ghostty",
                windowTitle: activeWindow.title,
                windowPersistenceName: activeWindow.persistenceName,
                windowLegacyPersistenceNames: activeWindow.legacyPersistenceNames,
                terminalID: terminalIDs?[index],
                bounds: frame,
                windowBounds: activeWindow.bounds,
                isFocused: focusedFrame.map { samePhysicalWindow($0, frame) || intersectionOverUnion($0, frame) > 0.8 } ?? false
            )
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

            let visibleChildren = axElements(element, kAXVisibleChildrenAttribute)
            let children = visibleChildren.isEmpty
                ? axElements(element, kAXChildrenAttribute)
                : visibleChildren
            for child in children {
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
            let persistenceKey = persistenceKey(for: detectedSplit)
            let legacyPersistenceKeys = legacyPersistenceKeys(
                for: detectedSplit,
                primaryKey: persistenceKey,
                previousKey: persistenceKeyBySplitID[splitID]
            )
            usedIDs.insert(splitID)
            splits.append(
                GhosttySplit(
                    id: splitID,
                    title: detectedSplit.title,
                    persistenceKey: persistenceKey,
                    legacyPersistenceKeys: legacyPersistenceKeys,
                    bounds: detectedSplit.bounds,
                    windowBounds: detectedSplit.windowBounds,
                    isFocused: detectedSplit.isFocused
                )
            )
        }

        for split in splits {
            knownBoundsBySplitID[split.id] = split.bounds
            knownWindowBoundsBySplitID[split.id] = split.windowBounds
            knownRelativeBoundsBySplitID[split.id] = relativeBounds(for: split.bounds, in: split.windowBounds)
            persistenceKeyBySplitID[split.id] = split.persistenceKey
        }

        return splits
    }

    private func persistenceKey(for split: DetectedSplit) -> String {
        if let terminalID = split.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !terminalID.isEmpty {
            return "terminal:\(terminalID)"
        }

        return persistenceKey(for: split, windowName: split.windowPersistenceName)
    }

    private func legacyPersistenceKeys(
        for split: DetectedSplit,
        primaryKey: String,
        previousKey: String?
    ) -> [String] {
        let windowNames = [split.windowPersistenceName] + split.windowLegacyPersistenceNames
        let aliases = windowNames.flatMap { titleAliasesByWindowName[$0] ?? [] }
        let legacyWindowNames = windowNames + aliases
        let geometryKeys = uniqueStrings(legacyWindowNames)
            .filter { !$0.isEmpty }
            .map { persistenceKey(for: split, windowName: $0) }
        let previousKeys = previousKey.map { [$0] } ?? []

        return uniqueStrings(previousKeys + geometryKeys)
            .filter { $0 != primaryKey }
    }

    private func persistenceKey(for split: DetectedSplit, windowName: String) -> String {
        let windowTitle = normalizedTitle(windowName).isEmpty ? "Ghostty" : normalizedTitle(windowName)
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

    private func normalizedTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstMeaningfulTitle(_ titles: String...) -> String? {
        titles
            .map(normalizedTitle)
            .first { !$0.isEmpty && $0 != "Ghostty" }
    }

    private func matchingVisibleWindow(
        forFrame frame: CGRect,
        title: String,
        in visibleWindows: [GhosttyWindow]
    ) -> GhosttyWindow? {
        let normalized = normalizedTitle(title)
        return visibleWindows.first {
            samePhysicalWindow($0.bounds, frame) &&
                (normalized.isEmpty || normalizedTitle($0.title) == normalized)
        } ?? visibleWindows.first {
            samePhysicalWindow($0.bounds, frame)
        }
    }

    private func persistenceWindowName(
        forTitle title: String,
        visibleWindow: GhosttyWindow?,
        visibleWindows: [GhosttyWindow],
        app: NSRunningApplication,
        frame: CGRect
    ) -> String {
        if let visibleWindow {
            return "window:\(app.processIdentifier):\(visibleWindow.id)"
        }

        let normalized = normalizedTitle(title)
        if !normalized.isEmpty, normalized != "Ghostty" {
            return "title:\(normalized)"
        }

        return "window:\(app.processIdentifier):unmatched"
    }

    private func rememberWindowTitle(_ window: ActiveGhosttyWindow) {
        let title = normalizedTitle(window.title)
        guard !title.isEmpty, title != "Ghostty" else {
            return
        }

        titleAliasesByWindowName[window.persistenceName, default: []].insert(title)
        for legacyName in window.legacyPersistenceNames {
            titleAliasesByWindowName[legacyName, default: []].insert(title)
        }
    }

    private func bestExistingSplitID(for detectedSplit: DetectedSplit, excluding usedIDs: Set<SplitID>) -> SplitID? {
        var bestMatch: (id: SplitID, score: CGFloat)?
        let detectedRelativeBounds = relativeBounds(for: detectedSplit.bounds, in: detectedSplit.windowBounds)

        for (splitID, previousRelativeBounds) in knownRelativeBoundsBySplitID where !usedIDs.contains(splitID) {
            let relativeOverlapScore = intersectionOverUnion(previousRelativeBounds, detectedRelativeBounds) * 1000
            let relativeFrameScore = sameRelativeSplit(previousRelativeBounds, detectedRelativeBounds) ? CGFloat(500) : 0
            let score = relativeOverlapScore + relativeFrameScore

            if bestMatch == nil || score > bestMatch!.score {
                bestMatch = (splitID, score)
            }
        }

        guard let bestMatch, bestMatch.score >= 500 else {
            return nil
        }

        return bestMatch.id
    }

    private func relativeBounds(for frame: CGRect, in window: CGRect) -> CGRect {
        guard window.width > 0, window.height > 0 else {
            return frame
        }

        return CGRect(
            x: (frame.minX - window.minX) / window.width,
            y: (frame.minY - window.minY) / window.height,
            width: frame.width / window.width,
            height: frame.height / window.height
        )
    }

    private func parseRelativePersistenceKey(_ key: String) -> ParsedRelativePersistenceKey? {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 6,
              parts[1] == "relative",
              let x = Double(parts[2]),
              let y = Double(parts[3]),
              let width = Double(parts[4]),
              let height = Double(parts[5])
        else {
            return nil
        }

        return ParsedRelativePersistenceKey(
            windowName: String(parts[0]),
            bounds: CGRect(x: x, y: y, width: width, height: height)
        )
    }

    private func newSplitID() -> SplitID {
        defer { nextSplitNumber += 1 }
        return "split-\(nextSplitNumber)"
    }

    private func isGhosttyFrontmost() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        return isGhosttyApplication(app)
    }

    private func isHelperFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private func activateGhostty() {
        ghosttyApplication()?.activate(options: [.activateIgnoringOtherApps])
    }

    private func ghosttyApplication() -> NSRunningApplication? {
        if let cachedGhosttyApplication,
           !cachedGhosttyApplication.isTerminated {
            return cachedGhosttyApplication
        }

        let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.mitchellh.ghostty")
            .first ?? NSWorkspace.shared.runningApplications.first { isGhosttyApplication($0) }
        cachedGhosttyApplication = app
        return app
    }

    private func isGhosttyApplication(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == "com.mitchellh.ghostty" || app.localizedName == "Ghostty"
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
        let splitTopLeft = appKitPoint(fromQuartzPoint: CGPoint(x: splitBounds.minX, y: splitBounds.minY))
        let splitTopRight = appKitPoint(fromQuartzPoint: CGPoint(x: splitBounds.maxX, y: splitBounds.minY))
        let splitLeft = min(splitTopLeft.x, splitTopRight.x)
        let splitRight = max(splitTopLeft.x, splitTopRight.x)
        let splitMidX = splitLeft + (splitRight - splitLeft) / 2
        let x: CGFloat

        switch position {
        case .topLeft:
            x = splitLeft + 18
        case .topCenter:
            x = splitMidX - size.width / 2
        case .topRight:
            x = splitRight - size.width - 18
        }

        let y = splitTopLeft.y - size.height - 12
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func badgeSize(for text: String) -> NSSize {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ]
        let measured = (text as NSString).size(withAttributes: attributes)
        return NSSize(width: min(max(measured.width + 32, 86), 360), height: 30)
    }

    private func appKitPoint(fromQuartzPoint point: CGPoint) -> NSPoint {
        if let display = displayContainingQuartzPoint(point) {
            return NSPoint(
                x: display.screen.frame.minX + point.x - display.bounds.minX,
                y: display.screen.frame.maxY - (point.y - display.bounds.minY)
            )
        }

        let maxY = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        return NSPoint(x: point.x, y: maxY - point.y)
    }

    private func displayContainingQuartzPoint(_ point: CGPoint) -> (screen: NSScreen, bounds: CGRect)? {
        let displays = screenDisplayPairs()
        if let display = displays.first(where: { $0.bounds.contains(point) }) {
            return display
        }

        return displays.min {
            distanceSquared(from: point, to: $0.bounds) < distanceSquared(from: point, to: $1.bounds)
        }
    }

    private func screenDisplayPairs() -> [(screen: NSScreen, bounds: CGRect)] {
        NSScreen.screens.compactMap { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            // When a display is unplugged, NSScreen.screens can transiently keep
            // the ghost screen while CGDisplayBounds collapses it to a 1x1 rect.
            // Mapping AX coordinates through that stale pair throws labels
            // off-screen, so only keep displays the window server still
            // considers active and geometrically real.
            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            guard CGDisplayIsActive(displayID) != 0 else {
                return nil
            }

            let bounds = CGDisplayBounds(displayID)
            guard bounds.width > 1, bounds.height > 1 else {
                return nil
            }

            return (screen: screen, bounds: bounds)
        }
    }

    private func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
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

private func uniqueStrings(_ strings: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []

    for string in strings where !seen.contains(string) {
        seen.insert(string)
        result.append(string)
    }

    return result
}

private func sameAXElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
    CFEqual(lhs, rhs)
}

private func samePhysicalWindow(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) <= 8 &&
        abs(lhs.minY - rhs.minY) <= 8 &&
        abs(lhs.width - rhs.width) <= 16 &&
        abs(lhs.height - rhs.height) <= 16
}

private func sameOverlayFrame(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
    abs(lhs.minX - rhs.minX) <= 0.5 &&
        abs(lhs.minY - rhs.minY) <= 0.5 &&
        abs(lhs.width - rhs.width) <= 0.5 &&
        abs(lhs.height - rhs.height) <= 0.5
}

private func sameRelativeSplit(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) <= 0.02 &&
        abs(lhs.minY - rhs.minY) <= 0.02 &&
        abs(lhs.width - rhs.width) <= 0.03 &&
        abs(lhs.height - rhs.height) <= 0.03
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

private func debugLog(_ message: String) {
    guard ghosttyLabelDebugLogging else {
        return
    }

    log(message)
}

private func log(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)

        if ghosttyLabelDebugFileLogging {
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
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
private let controller = LabelController()
controller.start()
RunLoop.main.run()
