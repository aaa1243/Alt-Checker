import AppKit

struct Row {
    var kind: String
    var user: String
    var account: String
    var source: String
    var note: String
}

enum ScanMode { case generic, minecraft, target }

func homeURL() -> URL { FileManager.default.homeDirectoryForCurrentUser }

func appSupport() -> URL {
    homeURL().appendingPathComponent("Library/Application Support", isDirectory: true)
}

func readText(_ url: URL, limit: Int = 8_000_000) -> String {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size < limit else { return "" }
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return "" }
    if data.count >= limit { return "" }
    return String(decoding: data, as: UTF8.self)
}

func regexGroups(_ text: String, _ pattern: String) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    return re.matches(in: text, options: [], range: full).map { match in
        (0..<match.numberOfRanges).map { i in
            let r = match.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

func walk(_ root: URL, limit: Int, allow: (URL, Int) -> Bool) -> [URL] {
    var out: [URL] = []
    guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) else { return out }
    for case let url as URL in en {
        if out.count >= limit { break }
        let path = url.path
        if path.contains("/app-") || path.contains("/modules/") || path.contains("/discord_desktop_core") { continue }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { continue }
        let size = values?.fileSize ?? 0
        if allow(url, size) { out.append(url) }
    }
    return out
}

func scanReport(mode: ScanMode, target: String) -> (text: String, names: [String]) {
    var rows: [Row] = []
    var seen = Set<String>()
    func add(_ kind: String, _ user: String, _ account: String, _ source: String, _ note: String) {
        var user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        var account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty && account.isEmpty { return }
        if user.count > 64 { user = String(user.prefix(64)) }
        if account.count > 120 { account = String(account.prefix(120)) }
        let key = "\(kind)|\(user)|\(account)".lowercased()
        if seen.contains(key) { return }
        seen.insert(key)
        rows.append(Row(kind: kind, user: user, account: account, source: source, note: note))
    }
    func addMinecraft(_ text: String, _ source: String) {
        if text.isEmpty { return }
        for m in regexGroups(text, #""minecraftProfile"\s*:\s*\{.{0,500}?"name"\s*:\s*"([A-Za-z0-9_]{3,16})".{0,800}?"username"\s*:\s*"([^"]{2,80})""#) {
            add("Minecraft Java", m[1], m[2], source, "")
        }
        for m in regexGroups(text, #""username"\s*:\s*"([^"]{2,80})".{0,800}?"minecraftProfile"\s*:\s*\{.{0,400}?"name"\s*:\s*"([A-Za-z0-9_]{3,16})""#) {
            add("Minecraft Java", m[2], m[1], source, "")
        }
        for m in regexGroups(text, #""displayName"\s*:\s*"([A-Za-z0-9_]{3,16})""#) {
            add("Minecraft", m[1], "", source, "")
        }
        for m in regexGroups(text, #""originalUsername"\s*:\s*"([A-Za-z0-9_]{3,16})".{0,300}?"minecraftUsername"\s*:\s*"([A-Za-z0-9_]{3,16})""#) {
            let note = m[1] == m[2] ? "" : "[RENAMED]"
            add("Minecraft", m[2], m[1], source, note)
        }
        for m in regexGroups(text, #"\{[^{}]*"name"\s*:\s*"([A-Za-z0-9_]{3,16})"[^{}]*"uuid"\s*:\s*"([^"]+)""#) {
            add("Minecraft", m[1], m[2], source, "(This username was found in the past on this Mac)")
        }
        for m in regexGroups(text, #"Loaded content for \[\s*([A-Za-z0-9_]{3,16})\s*\]"#) {
            add("Lunar", m[1], "", source, "")
        }
        for m in regexGroups(text, #"Got Lunar Client Token for \s*([A-Za-z0-9_]{3,16})"#) {
            add("Lunar", m[1], "", source, "")
        }
        for m in regexGroups(text, #"Auth config: mode=Authenticated,.*name=([A-Za-z0-9_]{3,16})"#) {
            add("Hytale", m[1], "", source, "")
        }
        for m in regexGroups(text, #"--name\s+([A-Za-z0-9_]{3,16})"#) {
            add("Minecraft", m[1], "", source, "")
        }
    }

    let support = appSupport()
    let home = homeURL()
    let mcNames = ["minecraft", "lunarclient", "Badlion Client", "feather", "Feather Launcher", "PrismLauncher", "MultiMC", "PolyMC", "ModrinthApp", "ATLauncher", "gdlauncher", "GDLauncher", "SKlauncher", "Minecraft Launcher", "TLauncher", ".tlauncher"]
    var mcDirs = mcNames.map { support.appendingPathComponent($0, isDirectory: true) }
    mcDirs.append(contentsOf: [".minecraft", ".lunarclient", ".feather"].map { home.appendingPathComponent($0, isDirectory: true) })
    let direct = [
        "minecraft/launcher_accounts.json",
        "minecraft/launcher_profiles.json",
        "minecraft/accounts.json",
        "minecraft/usercache.json",
        "minecraft/usernamecache.json",
        "feather/account.json",
        "feather/accounts.json"
    ]
    for rel in direct {
        let url = support.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: url.path) { addMinecraft(readText(url), url.path) }
        let dot = home.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: dot.path) { addMinecraft(readText(dot), dot.path) }
    }
    let nameOK = try? NSRegularExpression(pattern: "(?i)account|launcher_accounts|launcher_profiles|usercache|usernamecache|\\.log$", options: [])
    for dir in mcDirs {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
        for file in walk(dir, limit: 80, allow: { url, size in
            size > 0 && size < 8_000_000 && (nameOK?.firstMatch(in: url.lastPathComponent, options: [], range: NSRange(location: 0, length: (url.lastPathComponent as NSString).length)) != nil)
        }) {
            addMinecraft(readText(file), file.path)
        }
    }

    if mode != .minecraft {
        let steam = support.appendingPathComponent("Steam/config/loginusers.vdf")
        if FileManager.default.fileExists(atPath: steam.path) {
            let text = readText(steam, limit: 2_000_000)
            for m in regexGroups(text, #""AccountName"\s*"([^"]+)".{0,400}?"PersonaName"\s*"([^"]+)""#) {
                add("Steam", m[2], m[1], steam.path, "")
            }
            for m in regexGroups(text, #""PersonaName"\s*"([^"]+)".{0,400}?"AccountName"\s*"([^"]+)""#) {
                add("Steam", m[1], m[2], steam.path, "")
            }
        }
        let discordNames = ["discord", "discordcanary", "discordptb", "discorddevelopment", "Lightcord", "ArmCord", "Vencord", "Vesktop"]
        let bad: Set<String> = ["discord", "null", "undefined", "username", "everyone", "here", "system", "webhook", "clyde", "unknown", "true", "false"]
        let patterns = [
            #""username"\s*:\s*"([^"\\]{2,32})".{0,180}?"id"\s*:\s*"(\d{17,20})""#,
            #""id"\s*:\s*"(\d{17,20})".{0,180}?"username"\s*:\s*"([^"\\]{2,32})""#,
            #""username"\s*:\s*"([^"\\]{2,32})".{0,120}?"global_name"\s*:\s*"([^"\\]{1,64})""#,
            #""global_name"\s*:\s*"([^"\\]{1,64})".{0,120}?"username"\s*:\s*"([^"\\]{2,32})""#
        ]
        for name in discordNames {
            let root = support.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let preferred = ["Local Storage/leveldb", "Session Storage", "logs", "IndexedDB", "Network"].map { root.appendingPathComponent($0, isDirectory: true) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            let scanRoots = preferred.isEmpty ? [root] : preferred
            for scanRoot in scanRoots {
                for file in walk(scanRoot, limit: 60, allow: { url, size in
                    let ext = url.pathExtension.lowercased()
                    return size > 0 && size < 20_000_000 && ["ldb", "log", "old", "sqlite", "json"].contains(ext)
                }) {
                    let text = readText(file, limit: 20_000_000)
                    if text.isEmpty { continue }
                    for m in regexGroups(text, patterns[0]) where !bad.contains(m[1].lowercased()) {
                        add("Discord", m[1], m[2], file.path, "")
                    }
                    for m in regexGroups(text, patterns[1]) where !bad.contains(m[2].lowercased()) {
                        add("Discord", m[2], m[1], file.path, "")
                    }
                    for m in regexGroups(text, patterns[2]) where !bad.contains(m[1].lowercased()) {
                        let g = m[2] == "null" ? "" : m[2]
                        add("Discord", m[1], g, file.path, "")
                    }
                    for m in regexGroups(text, patterns[3]) where !bad.contains(m[2].lowercased()) {
                        let g = m[1] == "null" ? "" : m[1]
                        add("Discord", m[2], g, file.path, "")
                    }
                }
            }
        }
        if let users = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Users"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for user in users where !["Shared", "Guest"].contains(user.lastPathComponent) {
                add("Mac User", user.lastPathComponent, "", user.path, "")
            }
        }
    }

    if mode == .target {
        let q = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            rows = rows.filter { row in
                [row.user, row.account, row.source].contains { $0.range(of: q, options: .caseInsensitive) != nil }
            }
            var seenPath = Set<String>()
            var roots = ["Desktop", "Documents", "Downloads"].map { home.appendingPathComponent($0, isDirectory: true) }
            roots.append(contentsOf: mcDirs)
            roots.append(contentsOf: ["discord", "discordcanary", "discordptb", "Vencord", "Vesktop"].map { support.appendingPathComponent($0, isDirectory: true) })
            for root in roots {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { continue }
                for file in walk(root, limit: 40, allow: { url, _ in
                    url.lastPathComponent.range(of: q, options: .caseInsensitive) != nil
                }) {
                    if seenPath.contains(file.path) { continue }
                    seenPath.insert(file.path)
                    add("Target", q, file.path, "File name match", "")
                }
                for file in walk(root, limit: 80, allow: { url, size in
                    let ext = url.pathExtension.lowercased()
                    return size > 0 && size < 8_000_000 && ["json", "log", "txt", "ldb", "vdf", "old"].contains(ext)
                }) {
                    if seenPath.contains(file.path) { continue }
                    let text = readText(file)
                    guard text.range(of: q, options: .caseInsensitive) != nil else { continue }
                    seenPath.insert(file.path)
                    add("Target", q, file.path, "Text match", "")
                }
            }
        } else {
            rows = []
        }
    }

    let storeDir = support.appendingPathComponent("AltChecker", isDirectory: true)
    let store = storeDir.appendingPathComponent("previous.txt")
    let old = (try? String(contentsOf: store, encoding: .utf8))?.components(separatedBy: .newlines).filter { !$0.isEmpty } ?? []
    var names: [String] = []
    var lines: [String] = []
    if mode == .target { lines.append("Target: \(target)"); lines.append("") }
    if rows.isEmpty {
        lines.append("No accounts found.")
    } else {
        lines.append("Accounts Found: \(rows.count)")
        lines.append("")
        for row in rows {
            let past = !row.user.isEmpty && old.contains(row.user)
            lines.append(row.kind)
            if !row.user.isEmpty {
                lines.append(" [Username] \(row.user)")
                if !names.contains(row.user) { names.append(row.user) }
            }
            if !row.account.isEmpty { lines.append(" [Account]  \(row.account)") }
            if !row.note.isEmpty { lines.append(" \(row.note)") }
            if past && !row.note.lowercased().contains("past") {
                lines.append(" (This username was found in the past on this Mac)")
            }
            if !row.source.isEmpty { lines.append(" \(row.source)") }
            lines.append("")
        }
    }
    try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
    let all = Array(Set(old + names)).sorted()
    try? all.joined(separator: "\n").write(to: store, atomically: true, encoding: .utf8)
    lines.append("USN Journal Information")
    lines.append("USN Journal is a Windows NTFS log. It does not exist on macOS.")
    lines.append("")
    lines.append("Scan Complete")
    return (lines.joined(separator: "\n"), names)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var generic: NSButton!
    var minecraft: NSButton!
    var targetBtn: NSButton!
    var targetField: NSTextField!
    var start: NSButton!
    var status: NSTextField!
    var results: NSTextView!
    var mode: ScanMode = .generic
    var scanning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bg = NSColor(srgbRed: 16/255, green: 16/255, blue: 16/255, alpha: 1)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Alt Checker"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = bg
        window.center()
        let content = NSView(frame: window.contentView!.bounds)
        content.wantsLayer = true
        content.layer?.backgroundColor = bg.cgColor
        window.contentView = content

        generic = modeButton("Generic", "Minecraft, Discord, Steam, and Mac users")
        minecraft = modeButton("Minecraft", "Vanilla, Lunar, Badlion, Feather, Prism")
        targetBtn = modeButton("Target", "Find one username, any capitalization")
        generic.target = self; generic.action = #selector(pickGeneric)
        minecraft.target = self; minecraft.action = #selector(pickMinecraft)
        targetBtn.target = self; targetBtn.action = #selector(pickTarget)

        targetField = NSTextField(string: "")
        targetField.placeholderString = "username"
        targetField.font = .systemFont(ofSize: 14)
        targetField.textColor = .white
        targetField.backgroundColor = NSColor(srgbRed: 28/255, green: 28/255, blue: 28/255, alpha: 1)
        targetField.isBezeled = true
        targetField.bezelStyle = .roundedBezel
        targetField.isHidden = true
        targetField.translatesAutoresizingMaskIntoConstraints = false
        targetField.heightAnchor.constraint(equalToConstant: 28).isActive = true

        start = NSButton(title: "Start Scan", target: self, action: #selector(startScan))
        start.bezelStyle = .regularSquare
        start.isBordered = false
        start.wantsLayer = true
        start.layer?.backgroundColor = NSColor.white.cgColor
        start.layer?.cornerRadius = 8
        start.attributedTitle = NSAttributedString(string: "Start Scan", attributes: [.foregroundColor: bg, .font: NSFont.systemFont(ofSize: 14, weight: .semibold)])
        start.translatesAutoresizingMaskIntoConstraints = false
        start.heightAnchor.constraint(equalToConstant: 40).isActive = true

        status = NSTextField(labelWithString: "Pick a scan. The username box only opens for Target Scan.")
        status.textColor = NSColor(white: 0.65, alpha: 1)
        status.font = .systemFont(ofSize: 12)
        status.lineBreakMode = .byTruncatingTail

        results = NSTextView()
        results.isEditable = false
        results.isSelectable = true
        results.drawsBackground = true
        results.backgroundColor = NSColor(white: 0.08, alpha: 1)
        results.textColor = .white
        results.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        results.textContainerInset = NSSize(width: 8, height: 8)
        let scroll = NSScrollView()
        scroll.documentView = results
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let copy = NSButton(title: "Copy Usernames", target: self, action: #selector(copyNames))
        copy.bezelStyle = .regularSquare
        copy.isBordered = false
        copy.wantsLayer = true
        copy.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        copy.layer?.cornerRadius = 8
        copy.attributedTitle = NSAttributedString(string: "Copy Usernames", attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        copy.translatesAutoresizingMaskIntoConstraints = false
        copy.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let stack = NSStackView(views: [generic, minecraft, targetBtn, targetField, start, status, scroll, copy])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
        paintModes()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func modeButton(_ title: String, _ subtitle: String) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 10
        b.alignment = .left
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 48).isActive = true
        b.identifier = NSUserInterfaceItemIdentifier(subtitle)
        return b
    }

    func paintModes() {
        style(generic, "Generic", "Minecraft, Discord, Steam, and Mac users", mode == .generic)
        style(minecraft, "Minecraft", "Vanilla, Lunar, Badlion, Feather, Prism", mode == .minecraft)
        style(targetBtn, "Target", "Find one username, any capitalization", mode == .target)
        targetField.isHidden = mode != .target
    }

    func style(_ button: NSButton, _ title: String, _ subtitle: String, _ selected: Bool) {
        let fg: NSColor = selected ? NSColor(white: 0.06, alpha: 1) : .white
        let sub: NSColor = selected ? NSColor(white: 0.28, alpha: 1) : NSColor(white: 0.62, alpha: 1)
        let text = NSMutableAttributedString(string: "  \(title)\n", attributes: [.foregroundColor: fg, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        text.append(NSAttributedString(string: "  \(subtitle)", attributes: [.foregroundColor: sub, .font: NSFont.systemFont(ofSize: 11)]))
        button.attributedTitle = text
        button.layer?.backgroundColor = (selected ? NSColor.white : NSColor(white: 0.12, alpha: 1)).cgColor
    }

    @objc func pickGeneric() { mode = .generic; paintModes() }
    @objc func pickMinecraft() { mode = .minecraft; paintModes() }
    @objc func pickTarget() {
        mode = .target
        paintModes()
        window.makeFirstResponder(targetField)
    }

    @objc func startScan() {
        if scanning { return }
        if mode == .target && targetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status.stringValue = "Type a username first."
            window.makeFirstResponder(targetField)
            return
        }
        scanning = true
        start.isEnabled = false
        status.stringValue = "Scanning..."
        results.string = ""
        let chosen = mode
        let query = targetField.stringValue
        DispatchQueue.global(qos: .userInitiated).async {
            let report = scanReport(mode: chosen, target: query)
            DispatchQueue.main.async {
                self.results.string = report.text
                self.status.stringValue = "Scan complete"
                self.start.isEnabled = true
                self.scanning = false
            }
        }
    }

    @objc func copyNames() {
        let lines = results.string.components(separatedBy: .newlines)
        var names: [String] = []
        for line in lines where line.hasPrefix(" [Username] ") {
            let name = String(line.dropFirst(" [Username] ".count))
            if !name.isEmpty && !names.contains(name) { names.append(name) }
        }
        if names.isEmpty { status.stringValue = "No username to copy."; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
        status.stringValue = "Copied \(names.count) username(s)."
    }
}

private let appDelegate = AppDelegate()

@main
struct AppMain {
    static func main() {
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
