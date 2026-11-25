import Foundation
import AppKit
import CoreGraphics
import Carbon.HIToolbox

public enum RecordedShortcutResult: Equatable, Sendable {
    case preset(TriggerKeyOption)
    case custom(CustomHotkeySpec)
    case cancelled
}

/// Supports all Left & Right macOS single-modifier keys (`Fn`, `Left/Right Option`, `Left/Right Command`,
/// `Left/Right Control`, `Left/Right Shift`), `Option + Space`, and arbitrary custom Carbon combos,
/// in both Tap-to-Toggle and Hold-to-Talk modes, while ignoring the app's own synthetic typewriter keystrokes (`0x545A_5359`).
public final class HotkeyMonitor {
    /// Magic marker stamped onto every synthetic CGEvent emitted by this app so HotkeyMonitor NEVER confuses live typing with user combo keys!
    public static let syntheticEventMarker: Int64 = 0x545A_5359

    // IOKit `<IOKit/hidsystem/IOLLEvent.h>` device-dependent Left / Right modifier bitmasks
    public static let nxDeviceLeftCtrlMask: UInt   = 0x0000_0001
    public static let nxDeviceLeftShiftMask: UInt  = 0x0000_0002
    public static let nxDeviceRightShiftMask: UInt = 0x0000_0004
    public static let nxDeviceLeftCmdMask: UInt    = 0x0000_0008
    public static let nxDeviceRightCmdMask: UInt   = 0x0000_0010
    public static let nxDeviceLeftAltMask: UInt    = 0x0000_0020
    public static let nxDeviceRightAltMask: UInt   = 0x0000_0040
    public static let nxDeviceRightCtrlMask: UInt  = 0x0000_2000

    public var triggerOption: TriggerKeyOption = .fnKey {
        didSet {
            resetTransientKeyState()
            if isStarted {
                refreshCarbonHotKeyRegistration()
            }
        }
    }

    public var customSpec: CustomHotkeySpec = .default {
        didSet {
            if isStarted && triggerOption == .custom {
                refreshCarbonHotKeyRegistration()
            }
        }
    }

    public var behavior: TriggerBehavior = .tapToggle {
        didSet {
            resetTransientKeyState()
        }
    }

    public var onPrewarmMic: (() -> Void)?
    public var onTriggerStart: (() -> Void)?
    public var onTriggerStop: (() -> Void)?
    public var onCancel: (() -> Void)?
    /// Fires when the user physically presses bare `Return` / `Numpad Enter` / `Cmd+Return` (not Shift/Opt newline),
    /// allowing the app to immediately abort post-polish pasting if the user already sent the message!
    public var onUserSubmitKeyPressed: (() -> Void)?

    private var isStarted: Bool = false
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    private var carbonHotKeyRef: EventHotKeyRef?
    private var carbonEventHandlerRef: EventHandlerRef?

    private var isModifierPhysicallyDown: Bool = false
    private var otherKeyPressedDuringHold: Bool = false
    private var isRecordingToggledOn: Bool = false
    private var holdDidFireStart: Bool = false
    private var pendingHoldStartWorkItem: DispatchWorkItem?
    /// Prevents the release edge of a "stop press" from accidentally starting a new recording
    private var swallowNextReleaseAfterInstantStop: Bool = false

    // Interactive shortcut recorder state
    private var isCapturingShortcut: Bool = false
    private var captureLocalKeyMonitor: Any?
    private var captureLocalFlagsMonitor: Any?
    private var captureCandidateSingleModifier: TriggerKeyOption?
    private var captureSawOtherKey: Bool = false

    public init() {}

    deinit {
        stop()
    }

    public func syncRecordingState(_ active: Bool) {
        isRecordingToggledOn = active
        if !active {
            isModifierPhysicallyDown = false
            holdDidFireStart = false
            pendingHoldStartWorkItem?.cancel()
            pendingHoldStartWorkItem = nil
        }
    }

    private func resetTransientKeyState() {
        pendingHoldStartWorkItem?.cancel()
        pendingHoldStartWorkItem = nil
        isModifierPhysicallyDown = false
        otherKeyPressedDuringHold = false
        holdDidFireStart = false
        swallowNextReleaseAfterInstantStop = false
    }

    public func start() {
        stop()
        isStarted = true
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleRegularKeyDown(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleRegularKeyDown(event)
            return event
        }
        installCarbonEventHandlerIfNeeded()
        refreshCarbonHotKeyRegistration()
    }

    public func stop() {
        cancelInteractiveCapture()
        isStarted = false
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
        unregisterCarbonHotKey()
        if let handler = carbonEventHandlerRef {
            RemoveEventHandler(handler)
            carbonEventHandlerRef = nil
        }
        resetTransientKeyState()
        isRecordingToggledOn = false
    }

    // MARK: - Interactive Shortcut Recorder (Single Left/Right Modifier OR Combo Key)

    public func beginInteractiveCapture(completion: @escaping (RecordedShortcutResult) -> Void) {
        cancelInteractiveCapture()
        isCapturingShortcut = true
        captureCandidateSingleModifier = nil
        captureSawOtherKey = false

        captureLocalFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, self.isCapturingShortcut else { return event }
            let raw = event.modifierFlags.rawValue
            let activeFamilies = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])

            if !activeFamilies.isEmpty {
                if !self.captureSawOtherKey,
                   let singleOpt = Self.singleModifierOption(forKeyCode: event.keyCode, rawFlags: raw),
                   !Self.hasConflictingModifiers(option: singleOpt, rawFlags: raw) {
                    self.captureCandidateSingleModifier = singleOpt
                } else {
                    // Multiple modifiers held together -> wait for regular key combo
                    self.captureCandidateSingleModifier = nil
                    self.captureSawOtherKey = true
                }
            } else {
                // All modifiers released! If a clean single modifier was tapped alone, commit it immediately!
                if let chosenSingle = self.captureCandidateSingleModifier, !self.captureSawOtherKey {
                    self.finishInteractiveCapture(with: .preset(chosenSingle), completion: completion)
                } else {
                    self.captureCandidateSingleModifier = nil
                    self.captureSawOtherKey = false
                }
            }
            return nil
        }

        captureLocalKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isCapturingShortcut else { return event }
            self.captureSawOtherKey = true
            self.captureCandidateSingleModifier = nil

            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // Bare Esc cancels shortcut capture
            if event.keyCode == 53 && mods.isEmpty {
                self.finishInteractiveCapture(with: .cancelled, completion: completion)
                return nil
            }

            let isStandaloneFunctionKey = Self.isFunctionKey(event.keyCode)
            guard !mods.isEmpty || isStandaloneFunctionKey else {
                // Ignore bare letter/number press without modifier so user doesn't accidentally bind plain 'A'
                return nil
            }

            let carbonMods = Self.carbonModifiers(from: mods)
            if event.keyCode == 49 && carbonMods == UInt32(optionKey) {
                self.finishInteractiveCapture(with: .preset(.optionSpace), completion: completion)
                return nil
            }

            let label = Self.formatComboLabel(keyCode: event.keyCode, carbonModifiers: carbonMods)
            let spec = CustomHotkeySpec(keyCode: event.keyCode, carbonModifiers: carbonMods, label: label)
            self.finishInteractiveCapture(with: .custom(spec), completion: completion)
            return nil
        }
    }

    public func cancelInteractiveCapture() {
        isCapturingShortcut = false
        if let m = captureLocalFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = captureLocalKeyMonitor { NSEvent.removeMonitor(m) }
        captureLocalFlagsMonitor = nil
        captureLocalKeyMonitor = nil
        captureCandidateSingleModifier = nil
        captureSawOtherKey = false
    }

    private func finishInteractiveCapture(
        with result: RecordedShortcutResult,
        completion: @escaping (RecordedShortcutResult) -> Void
    ) {
        cancelInteractiveCapture()
        DispatchQueue.main.async {
            completion(result)
        }
    }

    // MARK: - Carbon Global Combo HotKey (`⌥ + Space` & Custom Combos — Zero Leaked Keystrokes)

    private func installCarbonEventHandlerIfNeeded() {
        guard carbonEventHandlerRef == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let eventRef, let userData else { return OSStatus(eventNotHandledErr) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                let kind = GetEventKind(eventRef)
                monitor.handleCarbonHotKeyEvent(kind: kind)
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            selfPtr,
            &carbonEventHandlerRef
        )
    }

    private func unregisterCarbonHotKey() {
        if let ref = carbonHotKeyRef {
            UnregisterEventHotKey(ref)
            carbonHotKeyRef = nil
        }
    }

    private func refreshCarbonHotKeyRegistration() {
        unregisterCarbonHotKey()
        guard !triggerOption.isSingleModifierKey else { return }

        let targetSpec: CustomHotkeySpec
        switch triggerOption {
        case .optionSpace:
            targetSpec = CustomHotkeySpec(keyCode: 49, carbonModifiers: UInt32(optionKey), label: "⌥ + Space")
        case .custom:
            targetSpec = customSpec
        default:
            return
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x545A_484B), id: 1) // 'TZHK'
        RegisterEventHotKey(
            UInt32(targetSpec.keyCode),
            targetSpec.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &carbonHotKeyRef
        )
    }

    private func handleCarbonHotKeyEvent(kind: UInt32) {
        guard !isCapturingShortcut, !triggerOption.isSingleModifierKey else { return }

        if kind == UInt32(kEventHotKeyPressed) {
            switch behavior {
            case .tapToggle:
                if isRecordingToggledOn {
                    isRecordingToggledOn = false
                    DispatchQueue.main.async { self.onTriggerStop?() }
                } else {
                    isRecordingToggledOn = true
                    DispatchQueue.main.async { self.onTriggerStart?() }
                }
            case .holdToTalk:
                if !isModifierPhysicallyDown {
                    isModifierPhysicallyDown = true
                    holdDidFireStart = true
                    isRecordingToggledOn = true
                    DispatchQueue.main.async { self.onTriggerStart?() }
                }
            }
        } else if kind == UInt32(kEventHotKeyReleased) {
            if behavior == .holdToTalk, isModifierPhysicallyDown {
                isModifierPhysicallyDown = false
                if holdDidFireStart {
                    holdDidFireStart = false
                    isRecordingToggledOn = false
                    DispatchQueue.main.async { self.onTriggerStop?() }
                }
            }
        }
    }

    // MARK: - Single-Modifier Event Handling (`flagsChanged` + `Esc` & Combo Cancellation)

    private func handleRegularKeyDown(_ event: NSEvent) {
        guard !isCapturingShortcut else { return }
        if let cg = event.cgEvent,
           cg.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return
        }

        if isModifierPhysicallyDown {
            otherKeyPressedDuringHold = true
            // If user pressed `⌘+C` or `⇧+A` during hold-to-talk, abort cleanly so normal shortcut works uninterrupted!
            if behavior == .holdToTalk {
                pendingHoldStartWorkItem?.cancel()
                pendingHoldStartWorkItem = nil
                if holdDidFireStart {
                    holdDidFireStart = false
                    isRecordingToggledOn = false
                    DispatchQueue.main.async { self.onCancel?() }
                }
                return
            }
        }

        if event.keyCode == 53 && isRecordingToggledOn {
            isRecordingToggledOn = false
            holdDidFireStart = false
            swallowNextReleaseAfterInstantStop = false
            DispatchQueue.main.async { self.onCancel?() }
            return
        }

        if Self.isUserSubmitEnterKey(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            DispatchQueue.main.async { self.onUserSubmitKeyPressed?() }
        }
    }

    public static func isUserSubmitEnterKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard keyCode == 36 || keyCode == 76 else { return false }
        // Shift+Enter / Option+Enter / Control+Enter are soft newlines inside chat boxes, not message send!
        if !modifiers.intersection([.shift, .option, .control]).isEmpty {
            return false
        }
        return true
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard !isCapturingShortcut, triggerOption.isSingleModifierKey else { return }
        if let cg = event.cgEvent,
           cg.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return
        }

        switch behavior {
        case .tapToggle:
            handleTapToggle(event)
        case .holdToTalk:
            handleHoldToTalk(event)
        }
    }

    private func handleTapToggle(_ event: NSEvent) {
        let rawFlags = event.modifierFlags.rawValue
        if swallowNextReleaseAfterInstantStop {
            if Self.matchesSingleModifierRelease(option: triggerOption, keyCode: event.keyCode, rawFlags: rawFlags) {
                swallowNextReleaseAfterInstantStop = false
                isModifierPhysicallyDown = false
            }
            return
        }

        if !isModifierPhysicallyDown {
            guard Self.matchesSingleModifierPress(option: triggerOption, keyCode: event.keyCode, rawFlags: rawFlags) else { return }
            isModifierPhysicallyDown = true
            otherKeyPressedDuringHold = false

            if isRecordingToggledOn {
                isRecordingToggledOn = false
                swallowNextReleaseAfterInstantStop = true
                DispatchQueue.main.async { self.onTriggerStop?() }
            } else {
                // KeyDown zero-wait mic pre-roll: wake hardware mic & fill pre-roll ring buffer BEFORE key release!
                DispatchQueue.main.async { self.onPrewarmMic?() }
            }
        } else {
            if Self.hasConflictingModifiers(option: triggerOption, rawFlags: rawFlags) {
                otherKeyPressedDuringHold = true
            }
            guard Self.matchesSingleModifierRelease(option: triggerOption, keyCode: event.keyCode, rawFlags: rawFlags) else { return }
            isModifierPhysicallyDown = false

            guard !otherKeyPressedDuringHold else { return }

            if !isRecordingToggledOn {
                isRecordingToggledOn = true
                DispatchQueue.main.async { self.onTriggerStart?() }
            }
        }
    }

    private func handleHoldToTalk(_ event: NSEvent) {
        let rawFlags = event.modifierFlags.rawValue
        if !isModifierPhysicallyDown {
            guard Self.matchesSingleModifierPress(option: triggerOption, keyCode: event.keyCode, rawFlags: rawFlags) else { return }
            isModifierPhysicallyDown = true
            otherKeyPressedDuringHold = false
            holdDidFireStart = false
            pendingHoldStartWorkItem?.cancel()
            pendingHoldStartWorkItem = nil

            if triggerOption.isComboProneLeftModifier {
                // Wake mic immediately on KeyDown so 140ms combo-debounce never clips the opening syllable!
                DispatchQueue.main.async { self.onPrewarmMic?() }
                // 140ms debounce on Left Cmd/Shift/Opt/Ctrl so `⌘+C` or `⇧+A` never triggers Tink sound!
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isModifierPhysicallyDown, !self.otherKeyPressedDuringHold else { return }
                    self.holdDidFireStart = true
                    self.isRecordingToggledOn = true
                    self.onTriggerStart?()
                }
                pendingHoldStartWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
            } else {
                holdDidFireStart = true
                isRecordingToggledOn = true
                DispatchQueue.main.async { self.onTriggerStart?() }
            }
        } else {
            if Self.hasConflictingModifiers(option: triggerOption, rawFlags: rawFlags) {
                otherKeyPressedDuringHold = true
                pendingHoldStartWorkItem?.cancel()
                pendingHoldStartWorkItem = nil
                if holdDidFireStart {
                    holdDidFireStart = false
                    isRecordingToggledOn = false
                    DispatchQueue.main.async { self.onCancel?() }
                }
            }
            guard Self.matchesSingleModifierRelease(option: triggerOption, keyCode: event.keyCode, rawFlags: rawFlags) else { return }
            pendingHoldStartWorkItem?.cancel()
            pendingHoldStartWorkItem = nil
            isModifierPhysicallyDown = false

            if holdDidFireStart && !otherKeyPressedDuringHold {
                holdDidFireStart = false
                isRecordingToggledOn = false
                DispatchQueue.main.async { self.onTriggerStop?() }
            } else {
                holdDidFireStart = false
            }
        }
    }

    // MARK: - Deterministic Pure Static Key Matchers (Left / Right Isolated & Self-Testable)

    public static func singleModifierOption(forKeyCode keyCode: UInt16, rawFlags: UInt) -> TriggerKeyOption? {
        let flags = NSEvent.ModifierFlags(rawValue: rawFlags)
        switch keyCode {
        case 63, 179:
            return flags.contains(.function) ? .fnKey : nil
        case 58:
            return flags.contains(.option) ? .leftOption : nil
        case 61:
            return flags.contains(.option) ? .rightOption : nil
        case 55:
            return flags.contains(.command) ? .leftCommand : nil
        case 54:
            return flags.contains(.command) ? .rightCommand : nil
        case 59:
            return flags.contains(.control) ? .leftControl : nil
        case 62:
            return flags.contains(.control) ? .rightControl : nil
        case 56:
            return flags.contains(.shift) ? .leftShift : nil
        case 60:
            return flags.contains(.shift) ? .rightShift : nil
        default:
            return nil
        }
    }

    public static func hasConflictingModifiers(option: TriggerKeyOption, rawFlags: UInt) -> Bool {
        let flags = NSEvent.ModifierFlags(rawValue: rawFlags)
        switch option {
        case .fnKey:
            return !flags.intersection([.command, .option, .control, .shift]).isEmpty
        case .leftOption:
            return !flags.intersection([.command, .control, .shift]).isEmpty || (rawFlags & nxDeviceRightAltMask) != 0
        case .rightOption:
            return !flags.intersection([.command, .control, .shift]).isEmpty || (rawFlags & nxDeviceLeftAltMask) != 0
        case .leftCommand:
            return !flags.intersection([.option, .control, .shift]).isEmpty || (rawFlags & nxDeviceRightCmdMask) != 0
        case .rightCommand:
            return !flags.intersection([.option, .control, .shift]).isEmpty || (rawFlags & nxDeviceLeftCmdMask) != 0
        case .leftControl:
            return !flags.intersection([.command, .option, .shift]).isEmpty || (rawFlags & nxDeviceRightCtrlMask) != 0
        case .rightControl:
            return !flags.intersection([.command, .option, .shift]).isEmpty || (rawFlags & nxDeviceLeftCtrlMask) != 0
        case .leftShift:
            return !flags.intersection([.command, .option, .control]).isEmpty || (rawFlags & nxDeviceRightShiftMask) != 0
        case .rightShift:
            return !flags.intersection([.command, .option, .control]).isEmpty || (rawFlags & nxDeviceLeftShiftMask) != 0
        case .optionSpace, .custom:
            return false
        }
    }

    public static func matchesSingleModifierPress(option: TriggerKeyOption, keyCode: UInt16, rawFlags: UInt) -> Bool {
        let flags = NSEvent.ModifierFlags(rawValue: rawFlags)
        guard !hasConflictingModifiers(option: option, rawFlags: rawFlags) else { return false }
        switch option {
        case .fnKey:
            return flags.contains(.function) && !flags.contains(.numericPad)
        case .leftOption:
            return keyCode == 58 && flags.contains(.option)
        case .rightOption:
            return keyCode == 61 && flags.contains(.option)
        case .leftCommand:
            return keyCode == 55 && flags.contains(.command)
        case .rightCommand:
            return keyCode == 54 && flags.contains(.command)
        case .leftControl:
            return keyCode == 59 && flags.contains(.control)
        case .rightControl:
            return keyCode == 62 && flags.contains(.control)
        case .leftShift:
            return keyCode == 56 && flags.contains(.shift)
        case .rightShift:
            return keyCode == 60 && flags.contains(.shift)
        case .optionSpace, .custom:
            return false
        }
    }

    public static func matchesSingleModifierRelease(option: TriggerKeyOption, keyCode: UInt16, rawFlags: UInt) -> Bool {
        let flags = NSEvent.ModifierFlags(rawValue: rawFlags)
        switch option {
        case .fnKey:
            return !flags.contains(.function)
        case .leftOption:
            return !flags.contains(.option) || (keyCode == 58 && (rawFlags & nxDeviceLeftAltMask) == 0)
        case .rightOption:
            return !flags.contains(.option) || (keyCode == 61 && (rawFlags & nxDeviceRightAltMask) == 0)
        case .leftCommand:
            return !flags.contains(.command) || (keyCode == 55 && (rawFlags & nxDeviceLeftCmdMask) == 0)
        case .rightCommand:
            return !flags.contains(.command) || (keyCode == 54 && (rawFlags & nxDeviceRightCmdMask) == 0)
        case .leftControl:
            return !flags.contains(.control) || (keyCode == 59 && (rawFlags & nxDeviceLeftCtrlMask) == 0)
        case .rightControl:
            return !flags.contains(.control) || (keyCode == 62 && (rawFlags & nxDeviceRightCtrlMask) == 0)
        case .leftShift:
            return !flags.contains(.shift) || (keyCode == 56 && (rawFlags & nxDeviceLeftShiftMask) == 0)
        case .rightShift:
            return !flags.contains(.shift) || (keyCode == 60 && (rawFlags & nxDeviceRightShiftMask) == 0)
        case .optionSpace, .custom:
            return false
        }
    }

    // MARK: - Shortcut Formatting Helpers

    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option)  { mask |= UInt32(optionKey) }
        if flags.contains(.shift)   { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    public static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        let fKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        return fKeyCodes.contains(keyCode)
    }

    public static func formatComboLabel(keyCode: UInt16, carbonModifiers: UInt32) -> String {
        var parts: [String] = []
        if (carbonModifiers & UInt32(controlKey)) != 0 { parts.append("⌃") }
        if (carbonModifiers & UInt32(optionKey)) != 0  { parts.append("⌥") }
        if (carbonModifiers & UInt32(shiftKey)) != 0   { parts.append("⇧") }
        if (carbonModifiers & UInt32(cmdKey)) != 0     { parts.append("⌘") }
        parts.append(keyName(for: keyCode))
        return parts.joined(separator: " + ")
    }

    public static func keyName(for keyCode: UInt16) -> String {
        let table: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
            20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
            29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
            46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
            100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
            107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
            123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return table[keyCode] ?? "Key\(keyCode)"
    }
}
