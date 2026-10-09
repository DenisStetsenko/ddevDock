import Cocoa
import ServiceManagement

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

    // Project name (or "*" for poweroff) -> verb while a ddev command runs.
    var busy: [String: String] = [:]

    // Cached `ddev list -j` result; the menu is built from this, never from
    // a live call. Refreshed by a timer, after commands, and on menu open.
    var projects: [DDEVProject] = []
    var fetchError: String?
    var loaded = false
    var refreshing = false
    let refreshInterval: TimeInterval = 10

    // PATH fix: GUI apps on macOS do not inherit the shell's PATH.
    // Adjust if your ddev binary lives elsewhere (`which ddev` in Terminal to check).
    let extraPathDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    // Override: `defaults write com.denstetsenko.ddevDock terminalApp iTerm`
    // (domain is `ddevDock` when run via `swift run` instead of the .app)
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

        refresh()
        Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // Runs `ddev list -j` off the main thread and stores the result.
    // Skips if a fetch is already in flight.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async {
            let (projects, error) = self.fetchProjects()
            DispatchQueue.main.async {
                self.projects = projects
                self.fetchError = error
                self.loaded = true
                self.refreshing = false
                let runningCount = projects.filter { self.statusKind($0.status) == .running }.count
                self.statusItem.button?.title = runningCount > 0 ? " \(runningCount)" : ""
            }
        }
    }

    // Rebuilds the menu from the cache every time it is opened, and kicks a
    // background refresh so the next open is fresher.
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        refresh()

        if let error = fetchError {
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if !loaded {
            let item = NSMenuItem(title: "Loading\u{2026}", action: nil, keyEquivalent: "")
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
        let stopAllItem = NSMenuItem(title: busy["*"] == nil ? "Stop All" : "Stopping all\u{2026}",
                                     action: #selector(stopAll), keyEquivalent: "")
        stopAllItem.target = self
        stopAllItem.isEnabled = busy["*"] == nil
        menu.addItem(stopAllItem)

        menu.addItem(NSMenuItem.separator())

        // Only meaningful from an .app bundle (make app); from `swift run` register() fails.
        // .requiresApproval: the user blocked it in System Settings > Login Items;
        // clicking again does nothing, so say where to fix it.
        let loginStatus = SMAppService.mainApp.status
        let loginTitle = loginStatus == .requiresApproval
            ? "Launch at Login (approve in System Settings)" : "Launch at Login"
        let loginItem = NSMenuItem(title: loginTitle, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = loginStatus == .enabled ? .on : .off
        menu.addItem(loginItem)

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

        if let verb = busy[p.name] ?? busy["*"] {
            item.title = "\(p.name) \u{2014} \(verb)\u{2026}"
            item.attributedTitle = nil
            item.isEnabled = false
            return item
        }

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
        let running = statusKind(p.status) == .running
        runDDEVAsync([running ? "stop" : "start", p.name],
                     busyKey: p.name, verb: running ? "Stopping" : "Starting")
    }

    @objc func restartProject(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? DDEVProject else { return }
        runDDEVAsync(["restart", p.name], busyKey: p.name, verb: "Restarting")
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
        runDDEVAsync(["poweroff"], busyKey: "*", verb: "Stopping all")
    }

    @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
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
        // Skip an empty PATH: a trailing ":" would put the current directory on it.
        let current = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (extraPathDirs + current).joined(separator: ":")
        // Every `ddev list` poll would otherwise log an Amplitude event
        // (~8600 a day at 10 s) and flush them over the network in batches.
        env["DDEV_NO_INSTRUMENTATION"] = "true"
        return env
    }

    // Runs start/stop/restart/poweroff in the background -- these take seconds,
    // running them synchronously would freeze the menu bar item.
    // `busyKey` marks the project (or "*" for all) as in progress until exit;
    // a non-zero exit shows the captured output in an alert.
    func runDDEVAsync(_ args: [String], busyKey: String, verb: String) {
        busy[busyKey] = verb
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["ddev"] + args
            task.environment = self.makeEnvironment()
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            var output = ""
            var status: Int32 = 127
            do {
                try task.run()
                // Read before waiting; a swallowed run() failure here would leave
                // the pipe open and this read blocked forever, with the project
                // stuck in "Starting…".
                output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                task.waitUntilExit()
                status = task.terminationStatus
            } catch {
                output = error.localizedDescription
            }

            DispatchQueue.main.async {
                self.busy[busyKey] = nil
                self.refresh()
                guard status != 0 else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "ddev \(args.joined(separator: " ")) failed (exit \(status))"
                alert.informativeText = output.split(separator: "\n").suffix(15).joined(separator: "\n")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
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
        // osascript blocks while the Automation permission dialog is up, and a
        // denied permission or missing app only shows up on stderr -- so run it
        // in the background and surface a non-zero exit.
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            let pipe = Pipe()
            task.standardError = pipe
            do { try task.run() } catch { return } // /usr/bin/osascript is always present
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            task.waitUntilExit()
            guard task.terminationStatus != 0 else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Could not open \(self.terminalAppName)"
                alert.informativeText = output.trimmingCharacters(in: .whitespacesAndNewlines)
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    // Blocking; always called from refresh() on a background queue.
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
        // Docker hung after sleep makes `ddev list` never return; without this the
        // `refreshing` flag stays set and the timer skips every tick forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            if task.isRunning { task.terminate() }
        }
        // Read before waiting -- the reverse order deadlocks on large output.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        if task.terminationReason == .uncaughtSignal {
            return ([], "ddev list timed out (30 s)")
        }
        if task.terminationStatus == 127 {
            return ([], "ddev not found (check PATH)")
        }
        let records = jsonLines(from: data)
        if task.terminationStatus != 0 {
            let msg = records.last { $0["level"] as? String == "fatal" || $0["level"] as? String == "error" }?["msg"] as? String
            let firstLine = msg?.split(separator: "\n").first.map(String.init)
            return ([], firstLine ?? "ddev list failed (exit \(task.terminationStatus))")
        }
        return (parseProjects(from: records), nil)
    }

    // With -j, ddev writes one JSON object per line: warnings (e.g. an update
    // notice) come before the {"level":"info","raw":[...]} line that holds the
    // project list. Parsing stdout as a single object breaks on the first warning.
    func jsonLines(from data: Data) -> [[String: Any]] {
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
    }

    // Verified against ddev v1.25.4: the project list lives in the `raw` key.
    func parseProjects(from records: [[String: Any]]) -> [DDEVProject] {
        let rawList = records.compactMap { $0["raw"] as? [[String: Any]] }.first ?? []

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
