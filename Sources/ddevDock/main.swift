import Cocoa

// MARK: - Data model

struct DDEVProject {
    let name: String
    let status: String       // ddev state: running / stopped / paused / starting / unhealthy / dir missing / config missing
    let approot: String      // project directory
    let primaryURL: String?
    let mailpitURL: String?
}

// MARK: - App

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // no Dock icon, no app switcher entry
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    var statusItem: NSStatusItem!
    let favoritesKey = "ddevFavorites"

    // PATH fix: GUI apps on macOS do not inherit the shell's PATH.
    // Adjust if your ddev binary lives elsewhere (`which ddev` in Terminal to check).
    let extraPathDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    // Override: `defaults write ddevDock terminalApp iTerm`
    var terminalAppName: String {
        UserDefaults.standard.string(forKey: "terminalApp") ?? "Terminal"
    }

    var favorites: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: favoritesKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // FIX 4: variableLength, not squareLength -- squareLength truncates a text title.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let url = Bundle.module.url(forResource: "icon", withExtension: "svg"),
           let icon = NSImage(contentsOf: url) {
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = true // follows menu bar light/dark appearance
            statusItem.button?.image = icon
            statusItem.button?.imagePosition = .imageLeading
        } else {
            statusItem.button?.title = "DDEV"
        }

        let menu = NSMenu()
        menu.delegate = self
        // FIX 2: AppKit overrides manual isEnabled while autoenablesItems is true.
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    // Rebuilds the menu every time it is opened. Only refresh point -- no timer,
    // no background polling. Note: this blocks the UI for the duration of
    // `ddev list -j` (typically well under a second).
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        let (projects, error) = fetchProjects()

        // Running count next to the icon. Refreshes only when the menu opens
        // until background polling lands.
        let runningCount = projects.filter { statusKind($0.status) == .running }.count
        statusItem.button?.title = runningCount > 0 ? " \(runningCount)" : ""

        if let error = error {
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if projects.isEmpty {
            let item = NSMenuItem(title: "No projects", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let favs = projects.filter { favorites.contains($0.name) }
            let others = projects.filter { !favorites.contains($0.name) }

            if !favs.isEmpty {
                let header = NSMenuItem(title: "Favorites", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for p in favs { menu.addItem(buildProjectItem(p)) }
                menu.addItem(NSMenuItem.separator())
            }

            for p in others { menu.addItem(buildProjectItem(p)) }
        }

        menu.addItem(NSMenuItem.separator())

        // FIX 3: explicit target, not responder-chain dispatch.
        let stopAllItem = NSMenuItem(title: "Stop All", action: #selector(stopAll), keyEquivalent: "")
        stopAllItem.target = self
        menu.addItem(stopAllItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // Status colors. Only "running" is green. Known idle states are gray.
    // Anything else -- including status strings this code does not know --
    // is treated as a problem and shown red, so an unexpected value is never
    // silently displayed as healthy.
    enum StatusKind {
        case running, idle, problem

        var color: NSColor {
            switch self {
            case .running: return .systemGreen
            case .idle:    return .systemGray
            case .problem: return .systemRed
            }
        }
    }

    func statusKind(_ status: String) -> StatusKind {
        switch status.lowercased() {
        case "running":
            return .running
        case "stopped", "paused", "starting":
            return .idle
        default:
            // ddev's remaining states: "unhealthy", "dir missing", "config missing".
            return .problem
        }
    }

    // A colored dot followed by the project name in the normal menu text color.
    func projectTitle(_ p: DDEVProject) -> NSAttributedString {
        let title = NSMutableAttributedString()

        let dot = NSAttributedString(
            string: "\u{25CF} ",
            attributes: [.foregroundColor: statusKind(p.status).color]
        )
        title.append(dot)

        let name = NSAttributedString(
            string: p.name,
            attributes: [.foregroundColor: NSColor.labelColor]
        )
        title.append(name)

        return title
    }

    func buildProjectItem(_ p: DDEVProject) -> NSMenuItem {
        let item = NSMenuItem(title: p.name, action: nil, keyEquivalent: "")
        item.attributedTitle = projectTitle(p)
        item.isEnabled = true

        let submenu = NSMenu()
        submenu.autoenablesItems = false // FIX 2, submenus need it too

        let running = statusKind(p.status) == .running
        let toggleTitle = running ? "Stop" : "Start"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleProject(_:)), keyEquivalent: "")
        toggleItem.representedObject = p
        toggleItem.target = self
        toggleItem.isEnabled = true
        submenu.addItem(toggleItem)

        let restartItem = NSMenuItem(title: "Restart", action: #selector(restartProject(_:)), keyEquivalent: "")
        restartItem.representedObject = p
        restartItem.target = self
        restartItem.isEnabled = running
        submenu.addItem(restartItem)

        let sshItem = NSMenuItem(title: "SSH", action: #selector(sshProject(_:)), keyEquivalent: "")
        sshItem.representedObject = p
        sshItem.target = self
        sshItem.isEnabled = running
        submenu.addItem(sshItem)

        let urlItem = NSMenuItem(title: "Open URL", action: #selector(openProjectURL(_:)), keyEquivalent: "")
        urlItem.representedObject = p
        urlItem.target = self
        urlItem.isEnabled = running && p.primaryURL != nil
        submenu.addItem(urlItem)

        let mailpitItem = NSMenuItem(title: "Mailpit", action: #selector(openMailpit(_:)), keyEquivalent: "")
        mailpitItem.representedObject = p
        mailpitItem.target = self
        mailpitItem.isEnabled = running && p.mailpitURL != nil
        submenu.addItem(mailpitItem)

        let finderItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "")
        finderItem.representedObject = p
        finderItem.target = self
        finderItem.isEnabled = !p.approot.isEmpty
        submenu.addItem(finderItem)

        submenu.addItem(NSMenuItem.separator())

        let isFav = favorites.contains(p.name)
        let favItem = NSMenuItem(
            title: isFav ? "Remove from Favorites" : "Add to Favorites",
            action: #selector(toggleFavorite(_:)),
            keyEquivalent: ""
        )
        favItem.representedObject = p
        favItem.target = self
        favItem.isEnabled = true
        submenu.addItem(favItem)

        item.submenu = submenu
        return item
    }

    // MARK: - Actions

    @objc func toggleProject(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? DDEVProject else { return }
        let cmd = statusKind(p.status) == .running ? "stop" : "start"
        runDDEVAsync([cmd, p.name])
    }

    @objc func restartProject(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? DDEVProject else { return }
        runDDEVAsync(["restart", p.name])
    }

    @objc func revealInFinder(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? DDEVProject, !p.approot.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.approot)])
    }

    // `-s` is the SERVICE flag (web/db), not the project. The project is a
    // positional argument: `ddev ssh <projectname>`.
    @objc func sshProject(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? DDEVProject else { return }
        openInTerminal(command: "ddev ssh \(shellQuote(p.name))")
    }

    @objc func openProjectURL(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? DDEVProject,
              let urlString = p.primaryURL, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func openMailpit(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? DDEVProject,
              let urlString = p.mailpitURL, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func toggleFavorite(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? DDEVProject else { return }
        var f = favorites
        if f.contains(p.name) { f.remove(p.name) } else { f.insert(p.name) }
        favorites = f
    }

    @objc func stopAll() {
        runDDEVAsync(["poweroff"])
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Escaping helpers

    // Wraps a path in single quotes for the shell, escaping embedded single quotes.
    func shellQuote(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // Escapes a string for embedding inside an AppleScript double-quoted literal.
    func appleScriptQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    // MARK: - Process helpers

    func makeEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = (extraPathDirs + [currentPath]).joined(separator: ":")
        return env
    }

    // Fire-and-forget for start/stop/poweroff -- these take seconds,
    // running them synchronously would freeze the menu bar item.
    func runDDEVAsync(_ args: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["ddev"] + args
            task.environment = self.makeEnvironment()
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }
    }

    func openInTerminal(command: String) {
        // `activate` fronts the terminal window; `do script` alone does not, and
        // NSWorkspace.launchApplication is deprecated since macOS 11.
        let appLiteral = appleScriptQuote(terminalAppName)
        let script = """
        tell application \(appLiteral)
            activate
            do script \(appleScriptQuote(command))
        end tell
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }

    // Synchronous on purpose: menuWillOpen needs the result before the menu displays.
    // Returns projects, or an error line for the menu. With -j, ddev reports
    // failures (e.g. Docker not running) as {"level":"fatal","msg":...} on
    // stdout with a non-zero exit; a missing binary makes env exit 127.
    func fetchProjects() -> ([DDEVProject], String?) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["ddev", "list", "-j"]
        task.environment = makeEnvironment()

        let pipe = Pipe()
        task.standardOutput = pipe
        // FIX 5: an unread Pipe deadlocks the process once its buffer fills.
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return ([], "ddev not found (check PATH)")
        }
        // Read before waiting -- the reverse order deadlocks on large output.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        if task.terminationStatus == 127 {
            return ([], "ddev not found (check PATH)")
        }
        if task.terminationStatus != 0 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["msg"] as? String
            let firstLine = msg?.split(separator: "\n").first.map(String.init)
            return ([], firstLine ?? "ddev list failed (exit \(task.terminationStatus))")
        }
        return (parseProjects(from: data), nil)
    }

    // NOT verified against a live `ddev list -j`. Handles the shapes seen across
    // ddev versions: a {"raw": [...]} wrapper and a bare array. Run `ddev list -j`
    // in Terminal and compare the keys before relying on this.
    func parseProjects(from data: Data) -> [DDEVProject] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }

        var rawList: [[String: Any]] = []
        if let topDict = json as? [String: Any],
           let raw = topDict["raw"] as? [[String: Any]] {
            rawList = raw
        } else if let topArray = json as? [[String: Any]] {
            rawList = topArray
        }

        return rawList.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            let status = (dict["status"] as? String) ?? "unknown"
            let approot = (dict["approot"] as? String) ?? ""
            let url = (dict["primary_url"] as? String)
                ?? (dict["httpsurl"] as? String)
                ?? (dict["httpurl"] as? String)
            let mailpit = (dict["mailpit_https_url"] as? String)
                ?? (dict["mailpit_url"] as? String)
            return DDEVProject(name: name, status: status, approot: approot, primaryURL: url, mailpitURL: mailpit)
        }
    }
}
