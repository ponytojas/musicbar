import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        statusController = StatusItemController()
    }

    /// `musicbar://` links; see `URLCommand`. Anything unrecognized is
    /// ignored.
    func application(_ application: NSApplication, open urls: [URL]) {
        for command in urls.compactMap(URLCommand.init(url:)) {
            statusController?.handle(command)
        }
    }

    /// Opening MusicBar while it is already running (Finder, Spotlight)
    /// shows its settings: the only way in while the item is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusController?.openSettings()
        return false
    }

    /// Never drawn — the app has no Dock icon or menu bar of its own — but
    /// it is what makes ⌘W and ⌘Q work while the settings window is in front.
    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: NSLocalizedString("About MusicBar", comment: ""),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: NSLocalizedString("Quit MusicBar", comment: ""),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // For the text fields in Settings: without these items ⌘C, ⌘V and
        // ⌘A do nothing there.
        let editMenu = NSMenu(title: NSLocalizedString("Edit", comment: ""))
        editMenu.addItem(withTitle: NSLocalizedString("Undo", comment: ""), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: NSLocalizedString("Cut", comment: ""), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: NSLocalizedString("Copy", comment: ""), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: NSLocalizedString("Paste", comment: ""), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: NSLocalizedString("Select All", comment: ""),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowMenu = NSMenu(title: NSLocalizedString("Window", comment: ""))
        windowMenu.addItem(
            withTitle: NSLocalizedString("Close", comment: ""),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        return mainMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
