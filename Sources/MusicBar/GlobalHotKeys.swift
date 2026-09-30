import Carbon.HIToolbox
import os

/// System-wide shortcuts through Carbon hot keys, which need no
/// Accessibility permission. Fixed ⌃⌥⌘ combinations; no recorder UI.
@MainActor
final class GlobalHotKeys {
    enum Action: UInt32, CaseIterable {
        case toggleCard = 1, toggleFavorite, addToPlaylist

        var keyCode: Int {
            switch self {
            case .toggleCard: kVK_ANSI_M
            case .toggleFavorite: kVK_ANSI_F
            case .addToPlaylist: kVK_ANSI_P
            }
        }
    }

    private static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    private static let signature: OSType = 0x4D42_6172 // 'MBar'

    private let onAction: (Action) -> Void
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?

    init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
    }

    func setEnabled(_ enabled: Bool) {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        guard enabled else { return }
        installHandlerIfNeeded()
        for action in Action.allCases {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(action.keyCode),
                Self.modifiers,
                EventHotKeyID(signature: Self.signature, id: action.rawValue),
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
            } else {
                // Another app already owns the combination.
                Logger.musicBar.error("Hot key \(action.rawValue, privacy: .public) unavailable (\(status, privacy: .public))")
            }
        }
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
        guard let action = Action(rawValue: id) else { return }
        onAction(action)
    }
}
