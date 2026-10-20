import Cocoa
import ApplicationServices
import Darwin
import Foundation

struct Frame: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct Node: Codable {
    let role: String
    let frame: Frame
    let texts: [String]
    let children: [Node]
}

struct Snapshot: Codable {
    let app: String
    let capturedAt: String
    let tree: Node
}

let stringAttributeNames: [String] = [
    kAXTitleAttribute as String,
    kAXDescriptionAttribute as String,
    kAXValueAttribute as String,
    kAXHelpAttribute as String,
    kAXRoleDescriptionAttribute as String,
    kAXIdentifierAttribute as String,
]

let maxNodes = 8000
let ownMenuTitles: Set<String> = ["File", "Edit", "View", "Convert", "Speech", "Window", "Help"]
var emittedNodes = 0
var sawPermissionDenied = false
var targetPID: pid_t = 0

func runningArch() -> String {
    #if arch(x86_64)
    return "x86_64"
    #elseif arch(arm64)
    return "arm64"
    #else
    return "unknown"
    #endif
}

func binaryPath() -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    var size = UInt32(buffer.count)
    if _NSGetExecutablePath(&buffer, &size) == 0 {
        return String(cString: buffer)
    }
    return CommandLine.arguments[0]
}

func denyPermissionAndExit() -> Never {
    let path = binaryPath()
    fputs(
        "Accessibility permission denied.\nGrant Accessibility access to this binary:\n\(path)\n",
        stderr
    )
    exit(2)
}

func ensureTrusted() {
    if AXIsProcessTrusted() {
        return
    }
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [key: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    if !AXIsProcessTrusted() {
        denyPermissionAndExit()
    }
}

func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    if error == .apiDisabled {
        sawPermissionDenied = true
        return nil
    }
    guard error == .success else {
        return nil
    }
    return value
}

func finite(_ number: CGFloat) -> Double {
    let value = Double(number)
    return value.isFinite ? value : 0
}

func axPoint(_ raw: CFTypeRef) -> CGPoint? {
    guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let ax = raw as! AXValue
    guard AXValueGetType(ax) == .cgPoint else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(ax, .cgPoint, &point) else { return nil }
    return point
}

func axSize(_ raw: CFTypeRef) -> CGSize? {
    guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let ax = raw as! AXValue
    guard AXValueGetType(ax) == .cgSize else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(ax, .cgSize, &size) else { return nil }
    return size
}

func frameOf(_ element: AXUIElement) -> Frame {
    let origin = copyAttribute(element, kAXPositionAttribute as String).flatMap(axPoint) ?? .zero
    let size = copyAttribute(element, kAXSizeAttribute as String).flatMap(axSize) ?? .zero
    return Frame(
        x: finite(origin.x),
        y: finite(origin.y),
        width: finite(size.width),
        height: finite(size.height)
    )
}

func trimmed(_ text: String) -> String? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

func stringsFrom(_ raw: CFTypeRef) -> [String] {
    let typeID = CFGetTypeID(raw)
    if typeID == CFStringGetTypeID() {
        return trimmed(raw as! String).map { [$0] } ?? []
    }
    if typeID == CFAttributedStringGetTypeID() {
        return trimmed((raw as! NSAttributedString).string).map { [$0] } ?? []
    }
    if typeID == CFNumberGetTypeID() {
        return trimmed((raw as! NSNumber).stringValue).map { [$0] } ?? []
    }
    if let list = raw as? [String] {
        return list.compactMap(trimmed)
    }
    return []
}

func textsOf(_ element: AXUIElement) -> [String] {
    var texts: [String] = []
    for name in stringAttributeNames {
        guard let raw = copyAttribute(element, name) else { continue }
        for text in stringsFrom(raw) where !texts.contains(text) {
            texts.append(text)
        }
    }
    return texts
}

func roleOf(_ element: AXUIElement) -> String {
    guard let raw = copyAttribute(element, kAXRoleAttribute as String) else {
        return "unknown"
    }
    return stringsFrom(raw).first ?? "unknown"
}

func elements(from raw: CFTypeRef) -> [AXUIElement] {
    if let list = raw as? [AXUIElement] {
        return list
    }
    guard CFGetTypeID(raw) == CFArrayGetTypeID() else {
        return []
    }
    let array = raw as! CFArray
    var list: [AXUIElement] = []
    list.reserveCapacity(CFArrayGetCount(array))
    for index in 0..<CFArrayGetCount(array) {
        guard let pointer = CFArrayGetValueAtIndex(array, index) else { continue }
        let element = Unmanaged<AXUIElement>.fromOpaque(pointer).takeUnretainedValue()
        list.append(element)
    }
    return list
}

func childrenOf(_ element: AXUIElement) -> [AXUIElement] {
    if let raw = copyAttribute(element, kAXChildrenAttribute as String) {
        let list = elements(from: raw)
        if !list.isEmpty {
            return list
        }
    }
    if let raw = copyAttribute(element, kAXWindowsAttribute as String) {
        return elements(from: raw)
    }
    return []
}

func elementPID(_ element: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return 0 }
    return pid
}

func belongsToTarget(_ element: AXUIElement) -> Bool {
    let pid = elementPID(element)
    return pid == 0 || targetPID == 0 || pid == targetPID
}

func attributeString(_ element: AXUIElement, _ name: String) -> String? {
    guard let raw = copyAttribute(element, name) else { return nil }
    return stringsFrom(raw).first
}

func includedChildren(of element: AXUIElement) -> [AXUIElement] {
    let children = childrenOf(element).filter(belongsToTarget)
    let role = roleOf(element)
    if role == "AXApplication" {
        return children.filter { child in
            let childRole = roleOf(child)
            return childRole == "AXWindow" || childRole == "AXMenuBar"
        }
    }
    if role == "AXMenuBar" {
        return children.filter { child in
            guard roleOf(child) == "AXMenuBarItem" else { return false }
            guard let title = attributeString(child, kAXTitleAttribute as String) else { return false }
            return ownMenuTitles.contains(title)
        }
    }
    return children
}

func readNode(_ element: AXUIElement, depth: Int) -> Node {
    let role = roleOf(element)
    let frame = frameOf(element)
    let texts = textsOf(element)
    if sawPermissionDenied || depth >= 40 || emittedNodes >= maxNodes {
        return Node(role: role, frame: frame, texts: texts, children: [])
    }
    emittedNodes += 1
    let children = includedChildren(of: element).map { readNode($0, depth: depth + 1) }
    return Node(role: role, frame: frame, texts: texts, children: children)
}

func countNodes(_ node: Node) -> Int {
    1 + node.children.reduce(0) { $0 + countNodes($1) }
}

func collectTexts(_ node: Node) -> [String] {
    node.texts + node.children.flatMap(collectTexts)
}

func openName(for target: String) -> String {
    if target.caseInsensitiveCompare("calculator") == .orderedSame {
        return "Calculator"
    }
    return target
}

func matches(_ app: NSRunningApplication, target: String) -> Bool {
    let needle = target.lowercased()
    if needle == "calculator", app.bundleIdentifier == "com.apple.calculator" {
        return true
    }
    if app.localizedName?.lowercased() == needle {
        return true
    }
    if app.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() == needle {
        return true
    }
    return false
}

func launch(_ target: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", openName(for: target)]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        fputs("open -a \(openName(for: target)) failed (\(process.terminationStatus))\n", stderr)
        exit(1)
    }
}

func findApp(_ target: String, timeout: TimeInterval) -> NSRunningApplication? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let app = NSWorkspace.shared.runningApplications.first(where: { matches($0, target: target) }) {
            return app
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return nil
}

func hasAllDigits(_ node: Node) -> Bool {
    let found = Set(collectTexts(node))
    return (0...9).allSatisfy { found.contains(String($0)) }
}

func writeSnapshot(_ snapshot: Snapshot, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(snapshot)
    try data.write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)
    var json = String(data: data, encoding: .utf8) ?? "{}"
    json = json.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
    json = json.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    let javascript = "window.SNAPSHOT = \(json);\n"
    try javascript.write(
        to: directory.appendingPathComponent("snapshot.js"),
        atomically: true,
        encoding: .utf8
    )
}

func isoTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
}

func captureTree(_ application: AXUIElement) -> Node? {
    sawPermissionDenied = false
    emittedNodes = 0
    let tree = readNode(application, depth: 0)
    if sawPermissionDenied {
        denyPermissionAndExit()
    }
    if tree.children.isEmpty && tree.texts.isEmpty {
        return nil
    }
    return tree
}

func waitForTree(_ application: AXUIElement) -> Node? {
    var latest: Node?
    let deadline = Date().addingTimeInterval(20)
    repeat {
        latest = captureTree(application)
        if let tree = latest, hasAllDigits(tree) {
            return tree
        }
        Thread.sleep(forTimeInterval: 0.3)
    } while Date() < deadline
    return latest
}

func treeSignature(_ node: Node) -> String {
    let frame = "\(Int(node.frame.x.rounded())):\(Int(node.frame.y.rounded())):\(Int(node.frame.width.rounded())):\(Int(node.frame.height.rounded()))"
    let texts = node.texts.joined(separator: "\u{1f}")
    let children = node.children.map(treeSignature).joined(separator: "\u{1e}")
    return "\(node.role)\u{1d}\(frame)\u{1d}\(texts)\u{1d}\(children)"
}

func publish(_ snapshot: Snapshot) {
    struct Event: Encodable {
        let subject: String
        let payload: Snapshot
    }
    guard let url = URL(string: "http://127.0.0.1:47653/events") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 2
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let body = try? encoder.encode(Event(subject: "gui.changed", payload: snapshot)) else { return }
    request.httpBody = body
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForResource = 2
    let session = URLSession(configuration: configuration)
    session.dataTask(with: request) { _, _, error in
        if let error = error {
            fputs("publish failed: \(error.localizedDescription)\n", stderr)
        }
        session.finishTasksAndInvalidate()
    }.resume()
}

let watchNotifications: [String] = [
    kAXValueChangedNotification as String,
    kAXFocusedUIElementChangedNotification as String,
    kAXTitleChangedNotification as String,
    kAXSelectedChildrenChangedNotification as String,
    kAXCreatedNotification as String,
    kAXUIElementDestroyedNotification as String,
    kAXWindowCreatedNotification as String,
    kAXLayoutChangedNotification as String,
    kAXMovedNotification as String,
    kAXResizedNotification as String,
]

let axNotificationCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon = refcon else { return }
    let watcher = Unmanaged<UIWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.scheduleRefresh()
}

final class UIWatcher {
    let application: AXUIElement
    let outputDir: URL
    let appName: String
    var observer: AXObserver?
    var debounceTimer: CFRunLoopTimer?
    var lastSignature = ""
    var refcon: UnsafeMutableRawPointer?

    init(application: AXUIElement, outputDir: URL, appName: String) {
        self.application = application
        self.outputDir = outputDir
        self.appName = appName
    }

    func start() {
        refcon = Unmanaged.passUnretained(self).toOpaque()
        _ = refresh(force: true)
        if installObserver() {
            fputs("watching with AXObserver\n", stderr)
            CFRunLoopRun()
        } else {
            fputs("polling for UI changes\n", stderr)
            poll()
        }
    }

    func installObserver() -> Bool {
        var created: AXObserver?
        let error = AXObserverCreate(targetPID, axNotificationCallback, &created)
        guard error == .success, let created = created, let refcon = refcon else {
            return false
        }
        observer = created
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
        let added = bindTree(application, depth: 0, observer: created, refcon: refcon)
        return added > 0
    }

    @discardableResult
    func bindTree(_ element: AXUIElement, depth: Int, observer: AXObserver, refcon: UnsafeMutableRawPointer) -> Int {
        var added = bind(element, observer: observer, refcon: refcon)
        if depth >= 8 {
            return added
        }
        for child in includedChildren(of: element) {
            added += bindTree(child, depth: depth + 1, observer: observer, refcon: refcon)
        }
        return added
    }

    func bind(_ element: AXUIElement, observer: AXObserver, refcon: UnsafeMutableRawPointer) -> Int {
        var added = 0
        for name in watchNotifications {
            let result = AXObserverAddNotification(observer, element, name as CFString, refcon)
            if result == .success {
                added += 1
            }
        }
        return added
    }

    func scheduleRefresh() {
        if let timer = debounceTimer {
            CFRunLoopTimerInvalidate(timer)
            debounceTimer = nil
        }
        let fire = CFAbsoluteTimeGetCurrent() + 0.08
        guard let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, fire, 0, 0, 0, { _ in
            _ = self.refresh(force: false)
        }) else {
            return
        }
        debounceTimer = timer
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
    }

    @discardableResult
    func refresh(force: Bool) -> Bool {
        guard let tree = captureTree(application) else { return false }
        let signature = treeSignature(tree)
        if !force && signature == lastSignature {
            return false
        }
        lastSignature = signature
        let snapshot = Snapshot(app: appName, capturedAt: isoTimestamp(), tree: tree)
        do {
            try writeSnapshot(snapshot, to: outputDir)
        } catch {
            fputs("failed to write snapshot: \(error)\n", stderr)
        }
        publish(snapshot)
        if let observer = observer, let refcon = refcon {
            _ = bindTree(application, depth: 0, observer: observer, refcon: refcon)
        }
        fputs("published gui.changed\n", stderr)
        return true
    }

    func poll() {
        while true {
            _ = refresh(force: false)
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
}

var activeWatcher: UIWatcher?

struct ListedApp: Codable {
    let id: String
    let name: String
}

struct AppCatalog: Codable {
    let apps: [ListedApp]
}

func listAppsAndExit() -> Never {
    _ = NSApplication.shared
    var seen = Set<String>()
    var apps: [ListedApp] = []
    let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    for app in running {
        guard let name = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            continue
        }
        let id: String
        if app.bundleIdentifier == "com.apple.calculator" || name.caseInsensitiveCompare("Calculator") == .orderedSame {
            id = "calculator"
        } else {
            id = name
        }
        if seen.contains(id) {
            continue
        }
        seen.insert(id)
        apps.append(ListedApp(id: id, name: name))
    }
    if !seen.contains("calculator") {
        apps.append(ListedApp(id: "calculator", name: "Calculator"))
    }
    apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = (try? encoder.encode(AppCatalog(apps: apps))) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
    exit(0)
}

let arguments = CommandLine.arguments
if arguments.count >= 2 && arguments[1] == "apps" {
    listAppsAndExit()
}
if arguments.count < 3 {
    fputs("usage: gui-reader apps | gui-reader <targetApp> <outputDir> [watch]\n", stderr)
    exit(64)
}

let targetApp = arguments[1]
let outputDir = URL(fileURLWithPath: arguments[2], isDirectory: true)
let watch = arguments.count >= 4 && arguments[3] == "watch"

_ = NSApplication.shared
ensureTrusted()

do {
    try launch(targetApp)
} catch {
    fputs("failed to launch \(targetApp): \(error)\n", stderr)
    exit(1)
}

guard let running = findApp(targetApp, timeout: 15) else {
    fputs("could not find a running app for \(targetApp)\n", stderr)
    exit(1)
}

running.activate(options: [.activateIgnoringOtherApps])

targetPID = running.processIdentifier
let application = AXUIElementCreateApplication(targetPID)
AXUIElementSetMessagingTimeout(application, 2)
_ = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
_ = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

guard let tree = waitForTree(application) else {
    fputs("read produced no tree\n", stderr)
    exit(1)
}

let appName = running.localizedName ?? targetApp

if watch {
    let watcher = UIWatcher(application: application, outputDir: outputDir, appName: appName)
    activeWatcher = watcher
    watcher.start()
    exit(0)
}

let snapshot = Snapshot(app: appName, capturedAt: isoTimestamp(), tree: tree)
do {
    try writeSnapshot(snapshot, to: outputDir)
} catch {
    fputs("failed to write snapshot: \(error)\n", stderr)
    exit(1)
}

fputs("read \(snapshot.app): \(countNodes(tree)) nodes, arch \(runningArch())\n", stderr)
fputs("wrote \(outputDir.appendingPathComponent("snapshot.json").path)\n", stderr)
