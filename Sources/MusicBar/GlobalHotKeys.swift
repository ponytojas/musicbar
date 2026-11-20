import AppKit
import Carbon.HIToolbox
import os

/// A key plus modifiers, stored the way Carbon hot keys take them.
struct Shortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, …).
    var modifiers: UInt32
    /// The key as shown to the user, e.g. "M" or "→".
    var key: String

    var displayText: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key
    }

    /// A shortcut from a key press, or nil when it can't be a global one:
    /// without ⌃, ⌥ or ⌘ it would swallow ordinary typing everywhere.
    init?(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, characters: String?) {
        var carbon: UInt32 = 0
        if modifierFlags.contains(.control) { carbon |= UInt32(controlKey) }
        if modifierFlags.contains(.option) { carbon |= UInt32(optionKey) }
        if modifierFlags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if modifierFlags.contains(.command) { carbon |= UInt32(cmdKey) }
        guard carbon & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
        guard let key = Self.keyName(keyCode: keyCode, characters: characters) else { return nil }
        self.init(keyCode: UInt32(keyCode), modifiers: carbon, key: key)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    static func keyName(keyCode: UInt16, characters: String?) -> String? {
        if let special = specialKeys[Int(keyCode)] { return special }
        guard let characters = characters?.uppercased(),
              let first = characters.first,
              first.isLetter || first.isNumber || first.isPunctuation || first.isSymbol
        else { return nil }
        return String(first)
    }

    /// `shortcuts` with `action` set to `shortcut` (nil clears it). One
    /// combination can only do one thing, so any other action that had it
    /// loses it.
    static func assigning(
        _ shortcut: Shortcut?,
        to action: HotKeyAction,
        in shortcuts: [HotKeyAction: Shortcut]
    ) -> [HotKeyAction: Shortcut] {
        var result = shortcuts
        if let shortcut {
            result = result.filter { $0.value.keyCode != shortcut.keyCode || $0.value.modifiers != shortcut.modifiers }
        }
        result[action] = shortcut
        return result
    }

    static func encode(_ shortcuts: [HotKeyAction: Shortcut]) -> Data? {
        let byName = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        return try? JSONEncoder().encode(byName)
    }

    /// Unknown action names (from a newer or older version) are dropped.
    static func decode(_ data: Data) -> [HotKeyAction: Shortcut]? {
        guard let byName = try? JSONDecoder().decode([String: Shortcut].self, from: data) else { return nil }
        return Dictionary(uniqueKeysWithValues: byName.compactMap { name, shortcut in
            HotKeyAction(rawValue: name).map { ($0, shortcut) }
        })
    }
}

/// Things a global shortcut can do. The first three ship with a shortcut;
/// the rest start unassigned, since the media keys cover most of them.
enum HotKeyAction: String, CaseIterable, Sendable {
    case toggleCard, toggleFavorite, addToPlaylist, playPause, nextTrack, previousTrack
    case volumeUp, volumeDown, seekForward, seekBackward

    /// How far the seek shortcuts jump.
    static let seekSeconds = 10

    /// Carbon identifies hot keys by number.
    var id: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }

    init?(id: UInt32) {
        guard id >= 1, id <= Self.allCases.count else { return nil }
        self = Self.allCases[Int(id) - 1]
    }

    var title: String {
        switch self {
        case .toggleCard: NSLocalizedString("Show or hide the card", comment: "")
        case .toggleFavorite: NSLocalizedString("Favorite the song", comment: "")
        case .addToPlaylist: NSLocalizedString("Add the song to a playlist", comment: "")
        case .playPause: NSLocalizedString("Play or pause", comment: "")
        case .nextTrack: NSLocalizedString("Next Track", comment: "")
        case .previousTrack: NSLocalizedString("Previous Track", comment: "")
        case .volumeUp: NSLocalizedString("Volume up", comment: "")
        case .volumeDown: NSLocalizedString("Volume down", comment: "")
        case .seekForward: NSLocalizedString("Skip forward 10 seconds", comment: "")
        case .seekBackward: NSLocalizedString("Skip back 10 seconds", comment: "")
        }
    }

    static let defaultShortcuts: [HotKeyAction: Shortcut] = {
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        return [
            .toggleCard: Shortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: modifiers, key: "M"),
            .toggleFavorite: Shortcut(keyCode: UInt32(kVK_ANSI_F), modifiers: modifiers, key: "F"),
            .addToPlaylist: Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: modifiers, key: "P"),
        ]
    }()
}

/// System-wide shortcuts through Carbon hot keys, which need no
/// Accessibility permission.
@MainActor
final class GlobalHotKeys {
    private static let signature: OSType = 0x4D42_6172 // 'MBar'

    private let onAction: (HotKeyAction) -> Void
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?

    init(onAction: @escaping (HotKeyAction) -> Void) {
        self.onAction = onAction
    }

    /// Replaces every registered hot key with `shortcuts`. Returns the
    /// actions whose shortcut macOS refused, usually because another app
    /// already owns the combination.
    @discardableResult
    func register(_ shortcuts: [HotKeyAction: Shortcut]) -> Set<HotKeyAction> {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        guard !shortcuts.isEmpty else { return [] }
        installHandlerIfNeeded()
        var unavailable: Set<HotKeyAction> = []
        for (action, shortcut) in shortcuts {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers,
                EventHotKeyID(signature: Self.signature, id: action.id),
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
            } else {
                unavailable.insert(action)
                Logger.musicBar.error("Hot key \(action.rawValue, privacy: .public) unavailable (\(status, privacy: .public))")
            }
        }
        return unavailable
    }

    /// App-lifetime object, so the handler is never removed.
    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let id = hotKeyID.id
                let hotKeys = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
                // Application-target Carbon events arrive on the main thread.
                MainActor.assumeIsolated { hotKeys.handle(id) }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    private func handle(_ id: UInt32) {
        guard let action = HotKeyAction(id: id) else { return }
        onAction(action)
    }
}
