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
var emittedNodes = 0
var sawPermissionDenied = false

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

func readNode(_ element: AXUIElement, depth: Int) -> Node {
    let role = roleOf(element)
    let frame = frameOf(element)
    let texts = textsOf(element)
    if sawPermissionDenied || depth >= 40 || emittedNodes >= maxNodes {
        return Node(role: role, frame: frame, texts: texts, children: [])
    }
    emittedNodes += 1
    let children = childrenOf(element).map { readNode($0, depth: depth + 1) }
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

let arguments = CommandLine.arguments
if arguments.count < 3 {
    fputs("usage: gui-reader <targetApp> <outputDir>\n", stderr)
    exit(64)
}

let targetApp = arguments[1]
let outputDir = URL(fileURLWithPath: arguments[2], isDirectory: true)

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

let application = AXUIElementCreateApplication(running.processIdentifier)
AXUIElementSetMessagingTimeout(application, 2)
_ = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
_ = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

var latest: Node?
let deadline = Date().addingTimeInterval(20)
repeat {
    sawPermissionDenied = false
    emittedNodes = 0
    let tree = readNode(application, depth: 0)
    if sawPermissionDenied {
        denyPermissionAndExit()
    }
    latest = tree
    if hasAllDigits(tree) {
        break
    }
    Thread.sleep(forTimeInterval: 0.3)
} while Date() < deadline

guard let tree = latest else {
    fputs("read produced no tree\n", stderr)
    exit(1)
}

if tree.children.isEmpty && tree.texts.isEmpty {
    fputs("accessibility tree was empty for \(running.localizedName ?? targetApp)\n", stderr)
    exit(1)
}

let snapshot = Snapshot(
    app: running.localizedName ?? targetApp,
    capturedAt: isoTimestamp(),
    tree: tree
)

do {
    try writeSnapshot(snapshot, to: outputDir)
} catch {
    fputs("failed to write snapshot: \(error)\n", stderr)
    exit(1)
}

fputs(
    "read \(snapshot.app): \(countNodes(tree)) nodes, arch \(runningArch())\n",
    stderr
)
fputs("wrote \(outputDir.appendingPathComponent("snapshot.json").path)\n", stderr)
