import Cocoa
import ServiceManagement
import UserNotifications

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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {

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
    // `ddev list -j` costs ~1.3 s wall / 0.7 s CPU with 20 projects, so the
    // timer only keeps the menu bar count fresh; opening the menu and running
    // a command refresh immediately anyway. Set in Settings…; 5 s floor.
    var refreshInterval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "refreshInterval")
        return v > 0 ? max(5, v) : 30
    }

    // PATH fix: GUI apps on macOS do not inherit the shell's PATH.
    // Adjust if your ddev binary lives elsewhere (`which ddev` in Terminal to check).
    let extraPathDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    // Set in Settings…; Terminal or iTerm, see openInTerminal().
    var terminalAppName: String {
        let v = UserDefaults.standard.string(forKey: "terminalApp") ?? ""
        return v.isEmpty ? "Terminal" : v
    }

    var favorites: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: favoritesKey) }
    }

    // UNUserNotificationCenter needs a bundle identifier; from `swift run` there is
    // none and the first call crashes.
    var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Registered defaults show up in the Settings fields; nothing is written to disk.
        UserDefaults.standard.register(defaults: ["refreshInterval": 30, "terminalApp": "Terminal"])

        if canNotify {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        // FIX 4: variableLength, not squareLength -- squareLength truncates a text title.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let url = Bundle.module.url(forResource: "icon", withExtension: "svg"),
           let icon = NSImage(contentsOf: url) {
            icon.size = NSSize(width: 16, height: 16)
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
        startTimer()

        // No one sees the count while the screen is off, and a locked Mac can
        // stay awake for hours -- stop polling. On wake, give Docker a few
        // seconds to come back before the first poll, so a half-started
        // container does not trigger a false "unhealthy" notification.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screenAsleep = true
            self?.timer?.invalidate()
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screenAsleep = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard let self, !self.screenAsleep else { return } // went dark again meanwhile
                self.refresh()
                self.startTimer()
            }
        }
    }

    var timer: Timer?
    var screenAsleep = false

    func startTimer() {
        timer?.invalidate()
        timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = refreshInterval / 3 // lets the system coalesce wake-ups
        // .common, not .default: a scheduledTimer never fires while a menu is
        // open (event-tracking mode), which is exactly when the live rebuild matters.
        RunLoop.main.add(timer!, forMode: .common)
    }

    // Runs `ddev list -j` off the main thread and stores the result.
    // Skips if a fetch is already in flight.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async {
            let (projects, error) = self.fetchProjects()
            DispatchQueue.main.async {
                self.notifyIfBroken(old: self.projects, new: projects)
                let changed = !self.loaded || error != self.fetchError
                    || projects.map { $0.name + $0.status } != self.projects.map { $0.name + $0.status }
                self.projects = projects
                self.fetchError = error
                self.loaded = true
                self.refreshing = false
                let runningCount = projects.filter { self.statusKind($0.status) == .running }.count
                self.statusItem.button?.title = runningCount > 0 ? " \(runningCount)" : ""
                if changed && self.menuIsOpen { self.rebuildMenu() }
            }
        }
    }

    // Posts a notification for each project that went from running to a problem
    // state (unhealthy, dir missing, config missing) between two polls. A stop
    // is the user's own doing, so it stays silent.
    func notifyIfBroken(old: [DDEVProject], new: [DDEVProject]) {
        guard canNotify else { return }
        let wasRunning = Set(old.filter { statusKind($0.status) == .running }.map(\.name))
        for p in new where wasRunning.contains(p.name) && statusKind(p.status) == .problem {
            let content = UNMutableNotificationContent()
            content.title = "\(p.name) is \(p.status)"
            content.sound = .default
            let request = UNNotificationRequest(identifier: p.name, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    // Without this the banner is suppressed whenever ddevDock counts as the
    // frontmost app (e.g. right after an alert).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Rebuilds the menu from the cache every time it is opened, and kicks a
    // background refresh. While the menu stays open, refresh() calls
    // rebuildMenu() again whenever a status changes, so "Starting…" turns into
    // a green dot without closing and reopening.
    var menuIsOpen = false

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        refresh()
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        // Replacing items collapses an open submenu, so this is only called when
        // something actually changed.
        menu.removeAllItems()

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
            let favorites = self.favorites // one UserDefaults read per menu open
            let favs = projects.filter { favorites.contains($0.name) }
            let others = projects.filter { !favorites.contains($0.name) }

            if !favs.isEmpty {
                let header = NSMenuItem(title: "Favorites", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for p in favs { menu.addItem(buildProjectItem(p, isFavorite: true)) }
                menu.addItem(NSMenuItem.separator())
            }

            for p in others { menu.addItem(buildProjectItem(p, isFavorite: false)) }
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

        let settingsItem = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

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

    func buildProjectItem(_ p: DDEVProject, isFavorite isFav: Bool) -> NSMenuItem {
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
            NSApp.activate()
            alert.runModal()
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Settings

    var settingsWindow: NSWindow?

    // Two fields bound straight to UserDefaults through NSUserDefaultsController:
    // no save button, a value is stored when the field loses focus or on Return.
    @objc func openSettings() {
        if settingsWindow == nil {
            func field(_ key: String, placeholder: String) -> NSTextField {
                let f = NSTextField()
                f.placeholderString = placeholder
                f.widthAnchor.constraint(equalToConstant: 180).isActive = true
                f.bind(.value, to: NSUserDefaultsController.shared, withKeyPath: "values.\(key)")
                return f
            }
            // Only terminals openInTerminal() can script, and only if installed.
            let terminals = ["Terminal", "iTerm"].filter { name in
                ["/System/Applications/Utilities", "/Applications"]
                    .contains { FileManager.default.fileExists(atPath: "\($0)/\(name).app") }
            }
            let terminalPopup = NSPopUpButton()
            terminalPopup.addItems(withTitles: terminals)
            terminalPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
            terminalPopup.bind(.selectedValue, to: NSUserDefaultsController.shared, withKeyPath: "values.terminalApp")

            let grid = NSGridView(views: [
                [NSTextField(labelWithString: "Terminal app:"), terminalPopup],
                [NSTextField(labelWithString: "Refresh every (s):"), field("refreshInterval", placeholder: "30")],
            ])
            grid.column(at: 0).xPlacement = .trailing
            grid.rowSpacing = 8
            grid.translatesAutoresizingMaskIntoConstraints = false

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "ddevDock Settings"
            window.isReleasedWhenClosed = false
            window.contentView!.addSubview(grid)
            NSLayoutConstraint.activate([
                grid.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
                grid.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
                grid.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
                grid.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
            ])
            window.center()
            settingsWindow = window

            // Restart the timer when the interval changes; favorites toggles also
            // land here, a spare restart costs nothing.
            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.startTimer()
            }
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
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
                if self.menuIsOpen { self.rebuildMenu() } // drop the "…" label even if the status did not change
                self.refresh()
                guard status != 0 else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "ddev \(args.joined(separator: " ")) failed (exit \(status))"
                alert.informativeText = output.split(separator: "\n").suffix(15).joined(separator: "\n")
                NSApp.activate()
                alert.runModal()
            }
        }
    }

    func openInTerminal(command: String) {
        // `activate` fronts the terminal window; `do script` alone does not, and
        // NSWorkspace.launchApplication is deprecated since macOS 11.
        let appLiteral = appleScriptQuote(terminalAppName)
        let commandLiteral = appleScriptQuote(command)
        // iTerm has its own dictionary: no `do script`, a window must be created first.
        let script = terminalAppName == "iTerm" ? """
        tell application \(appLiteral)
            activate
            create window with default profile
            tell current session of current window to write text \(commandLiteral)
        end tell
        """ : """
        tell application \(appLiteral)
            activate
            do script \(commandLiteral)
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
                NSApp.activate()
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
