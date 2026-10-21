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
    let id: String
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
    kAXPlaceholderValueAttribute as String,
    kAXSelectedTextAttribute as String,
]

let maxNodes = 8000
let ownMenuTitles: Set<String> = ["File", "Edit", "View", "Convert", "Speech", "Window", "Help"]
var emittedNodes = 0
var sawPermissionDenied = false
var targetPID: pid_t = 0
var targetAppName = ""

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
    if typeID == CFArrayGetTypeID() {
        let array = raw as! NSArray
        var out: [String] = []
        for index in 0..<array.count {
            let item = array.object(at: index)
            if let text = item as? String {
                out.append(contentsOf: trimmed(text).map { [$0] } ?? [])
            } else if let text = item as? NSAttributedString {
                out.append(contentsOf: trimmed(text.string).map { [$0] } ?? [])
            } else if let text = item as? NSNumber {
                out.append(contentsOf: trimmed(text.stringValue).map { [$0] } ?? [])
            }
        }
        return out
    }
    return []
}

func expandLines(_ texts: [String]) -> [String] {
    var out: [String] = []
    func add(_ text: String) {
        guard let text = trimmed(text), !out.contains(text) else { return }
        out.append(text)
    }
    for text in texts {
        add(text)
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard normalized.contains("\n") else { continue }
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: true) {
            add(String(line))
        }
    }
    return out
}

func extraStringAttributes(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(element, &names) == .success, let names = names as? [String] else {
        return []
    }
    return names.filter { name in
        if stringAttributeNames.contains(name) { return false }
        let lower = name.lowercased()
        return lower.contains("string") || lower.contains("label") || lower.contains("title")
            || lower.contains("value") || lower.contains("help") || lower.contains("description")
            || lower.contains("placeholder") || lower.contains("text")
    }
}

func textsOf(_ element: AXUIElement) -> [String] {
    var texts: [String] = []
    func absorb(_ names: [String]) {
        for name in names {
            guard let raw = copyAttribute(element, name) else { continue }
            for text in stringsFrom(raw) where !texts.contains(text) {
                texts.append(text)
            }
        }
    }
    absorb(stringAttributeNames)
    let role = roleOf(element)
    if texts.isEmpty && (role == "AXGroup" || role == "AXGeneric" || role == "AXScrollArea" || role == "AXOutline" || role == "AXRow" || role == "AXCell" || role == "AXStaticText" || role == "AXButton") {
        absorb(extraStringAttributes(element))
    }
    return expandLines(texts)
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

func elementList(_ raw: CFTypeRef) -> [AXUIElement] {
    if CFGetTypeID(raw) == AXUIElementGetTypeID() {
        return [raw as! AXUIElement]
    }
    return elements(from: raw)
}

func deduped(_ groups: [[AXUIElement]]) -> [AXUIElement] {
    var seen = Set<String>()
    var list: [AXUIElement] = []
    for group in groups {
        for element in group {
            let key = "\(Unmanaged.passUnretained(element).toOpaque())"
            if seen.insert(key).inserted {
                list.append(element)
            }
        }
    }
    return list
}

func childrenOf(_ element: AXUIElement) -> [AXUIElement] {
    let role = roleOf(element)
    var list: [AXUIElement] = []
    if let raw = copyAttribute(element, kAXChildrenAttribute as String) {
        list.append(contentsOf: elements(from: raw))
    }
    if role == "AXApplication" {
        let roles = Set(list.map(roleOf))
        if !roles.contains("AXWindow"), let raw = copyAttribute(element, kAXWindowsAttribute as String) {
            list.append(contentsOf: elements(from: raw))
        }
        if !roles.contains("AXMenuBar"), let raw = copyAttribute(element, kAXMenuBarAttribute as String) {
            list.append(contentsOf: elementList(raw))
        }
    }
    if list.isEmpty && (role == "AXScrollArea" || role == "AXWebArea" || role == "AXOutline" || role == "AXTable" || role == "AXList") {
        for name in [kAXVisibleChildrenAttribute as String, kAXContentsAttribute as String, kAXRowsAttribute as String] {
            if let raw = copyAttribute(element, name) {
                list.append(contentsOf: elementList(raw))
            }
        }
    }
    return deduped([list])
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
            if title == "Apple" { return false }
            if targetAppName.caseInsensitiveCompare("calculator") == .orderedSame {
                return ownMenuTitles.contains(title)
            }
            return true
        }
    }
    return children
}

func nodeID(_ parent: String, _ index: Int) -> String {
    return "\(parent)/\(index)"
}

func readNode(_ element: AXUIElement, depth: Int, id: String) -> Node {
    let role = roleOf(element)
    let frame = frameOf(element)
    let texts = textsOf(element)
    if sawPermissionDenied || depth >= 40 || emittedNodes >= maxNodes {
        return Node(id: id, role: role, frame: frame, texts: texts, children: [])
    }
    emittedNodes += 1
    let children = includedChildren(of: element).enumerated().map { index, child in
        readNode(child, depth: depth + 1, id: nodeID(id, index))
    }
    return Node(id: id, role: role, frame: frame, texts: texts, children: children)
}

func findElement(_ element: AXUIElement, id: String, target: String, depth: Int) -> AXUIElement? {
    if id == target {
        return element
    }
    if depth >= 40 {
        return nil
    }
    for (index, child) in includedChildren(of: element).enumerated() {
        if let found = findElement(child, id: nodeID(id, index), target: target, depth: depth + 1) {
            return found
        }
    }
    return nil
}

func actionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success, let names = names else {
        return []
    }
    return names as? [String] ?? []
}

func parentElement(_ element: AXUIElement) -> AXUIElement? {
    guard let raw = copyAttribute(element, kAXParentAttribute as String) else { return nil }
    guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
    return (raw as! AXUIElement)
}

func performAction(_ element: AXUIElement, _ name: String) -> Bool {
    guard actionNames(element).contains(name) else { return false }
    return AXUIElementPerformAction(element, name as CFString) == .success
}

func setSelected(_ element: AXUIElement) -> Bool {
    return AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
}

func postClick(_ point: CGPoint, nodeID: String, label: String) {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
        fputs("could not create a click for \(nodeID)\n", stderr)
        exit(1)
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    fputs("\(label) \(nodeID)\n", stderr)
}

func clickCenter(_ element: AXUIElement, nodeID: String) {
    let frame = frameOf(element)
    guard frame.width > 0, frame.height > 0 else {
        fputs("node \(nodeID) has no action and no frame\n", stderr)
        exit(1)
    }
    let point = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
    postClick(point, nodeID: nodeID, label: "clicked center of")
}

func windowElement(_ element: AXUIElement) -> AXUIElement? {
    var current: AXUIElement? = element
    for _ in 0..<20 {
        guard let node = current else { return nil }
        if roleOf(node) == "AXWindow" { return node }
        current = parentElement(node)
    }
    return nil
}

func navigationBackPoint(_ element: AXUIElement) -> CGPoint? {
    guard roleOf(element) == "AXStaticText", let window = windowElement(element) else { return nil }
    let text = frameOf(element)
    let win = frameOf(window)
    guard text.width > 40, text.height > 8, text.height < 48 else { return nil }
    let insetX = text.x - win.x
    let insetY = text.y - win.y
    guard insetX > 24, insetX < 80, insetY >= 0, insetY < 90 else { return nil }
    return CGPoint(x: win.x + 16, y: text.y + text.height / 2)
}

func insideWebArea(_ element: AXUIElement) -> Bool {
    var current: AXUIElement? = element
    for _ in 0..<24 {
        guard let node = current else { return false }
        let role = roleOf(node)
        if role == "AXWebArea" { return true }
        if role == "AXWindow" || role == "AXApplication" { return false }
        current = parentElement(node)
    }
    return false
}

func performClick(_ element: AXUIElement, nodeID: String) {
    if insideWebArea(element) {
        clickCenter(element, nodeID: nodeID)
        return
    }
    let pressable: Set<String> = ["AXButton", "AXRadioButton", "AXCheckBox", "AXLink", "AXMenuItem", "AXPopUpButton", "AXMenuButton"]
    if performAction(element, kAXPressAction as String) {
        fputs("pressed \(nodeID)\n", stderr)
        return
    }
    var current = element
    for _ in 0..<5 {
        guard let parent = parentElement(current) else { break }
        let role = roleOf(parent)
        if role == "AXApplication" || role == "AXWindow" || role == "AXMenuBar" { break }
        if role == "AXRow" && setSelected(parent) {
            fputs("selected row for \(nodeID)\n", stderr)
            return
        }
        if pressable.contains(role) && performAction(parent, kAXPressAction as String) {
            fputs("pressed ancestor for \(nodeID)\n", stderr)
            return
        }
        current = parent
    }
    if performAction(element, "AXPick") || performAction(element, kAXConfirmAction as String) {
        fputs("picked \(nodeID)\n", stderr)
        return
    }
    if performAction(element, kAXShowMenuAction as String) {
        fputs("showed menu for \(nodeID)\n", stderr)
        return
    }
    if let point = navigationBackPoint(element) {
        postClick(point, nodeID: nodeID, label: "clicked leading edge of")
        return
    }
    clickCenter(element, nodeID: nodeID)
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

var cachedMappedLines: [String]?

func x86Slice(_ data: Data) -> Data {
    guard data.count >= 8 else { return data }
    let magic = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
    // FAT_CIGAM is stored big-endian on disk; the little-endian load is 0xBEBAFECA.
    guard magic == 0xBEBAFECA else { return data }
    let count = Int(data.subdata(in: 4..<8).withUnsafeBytes { CFSwapInt32BigToHost($0.load(as: UInt32.self)) })
    var cursor = 8
    for _ in 0..<count {
        guard cursor + 20 <= data.count else { break }
        let fields = data.subdata(in: cursor..<(cursor + 20)).withUnsafeBytes { raw -> (UInt32, UInt32, UInt32) in
            let cpu = CFSwapInt32BigToHost(raw.load(fromByteOffset: 0, as: UInt32.self))
            let offset = CFSwapInt32BigToHost(raw.load(fromByteOffset: 8, as: UInt32.self))
            let size = CFSwapInt32BigToHost(raw.load(fromByteOffset: 12, as: UInt32.self))
            return (cpu, offset, size)
        }
        cursor += 20
        // CPU_TYPE_X86_64
        if fields.0 == 0x01000007 {
            let start = Int(fields.1)
            let end = start + Int(fields.2)
            guard end <= data.count else { return data }
            return data.subdata(in: start..<end)
        }
    }
    return data
}

func flutterImageData() -> Data? {
    guard targetPID != 0,
          let app = NSRunningApplication(processIdentifier: targetPID),
          let bundleURL = app.bundleURL else { return nil }
    let url = bundleURL.appendingPathComponent("Contents/Frameworks/App.framework/Versions/A/App")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return x86Slice(data)
}

func mappedDartLines() -> [String] {
    if let cachedMappedLines = cachedMappedLines {
        return cachedMappedLines
    }
    guard let data = flutterImageData() else {
        cachedMappedLines = []
        return []
    }
    var lines: [String] = []
    var seen = Set<String>()
    let bytes = [UInt8](data)
    var index = 0
    while index + 24 < bytes.count {
        if bytes[index + 2] == 0x05 && bytes[index + 3] == 0x00 {
            let length = Int(bytes[index + 8]) | (Int(bytes[index + 9]) << 8) | (Int(bytes[index + 10]) << 16) | (Int(bytes[index + 11]) << 24)
            let chars = length >> 1
            if length & 1 == 0 && chars >= 2 && chars <= 80 && index + 16 + chars <= bytes.count {
                let raw = bytes[(index + 16)..<(index + 16 + chars)]
                if raw.allSatisfy({ $0 >= 32 && $0 < 127 }) {
                    let text = String(bytes: raw, encoding: .utf8) ?? ""
                    if !text.isEmpty && seen.insert(text).inserted {
                        lines.append(text)
                    }
                    let step = 16 + ((chars + 15) & ~15)
                    index += max(step, 16)
                    continue
                }
            }
        }
        index += 16
    }
    cachedMappedLines = lines
    return lines
}

func linesInTree(_ node: Node, exact: inout Set<String>, buried: inout Set<String>) {
    for text in node.texts {
        exact.insert(text)
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard normalized.contains("\n") else { continue }
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: true) {
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                buried.insert(clean)
            }
        }
    }
    for child in node.children {
        linesInTree(child, exact: &exact, buried: &buried)
    }
}

func replacingWindowTexts(_ root: Node, texts: [String]) -> Node {
    let children = root.children.map { child -> Node in
        guard child.role == "AXWindow" else { return child }
        return Node(id: child.id, role: child.role, frame: child.frame, texts: texts, children: child.children)
    }
    return Node(id: root.id, role: root.role, frame: root.frame, texts: root.texts, children: children)
}

func mergeMappedLines(_ root: Node) -> Node {
    let mapped = mappedDartLines()
    guard !mapped.isEmpty else { return root }
    var exact = Set<String>()
    var buried = Set<String>()
    linesInTree(root, exact: &exact, buried: &buried)
    let visible = exact.union(buried)
    var recovered: [String] = []
    for line in mapped where visible.contains(line) && !exact.contains(line) {
        recovered.append(line)
    }
    guard !recovered.isEmpty, let window = root.children.first(where: { $0.role == "AXWindow" }) else {
        return root
    }
    var texts = window.texts
    for line in recovered where !texts.contains(line) {
        texts.append(line)
    }
    return replacingWindowTexts(root, texts: texts)
}

func captureTree(_ application: AXUIElement) -> Node? {
    sawPermissionDenied = false
    emittedNodes = 0
    let tree = readNode(application, depth: 0, id: "0")
    if sawPermissionDenied {
        denyPermissionAndExit()
    }
    if tree.children.isEmpty && tree.texts.isEmpty {
        return nil
    }
    return mergeMappedLines(tree)
}

func windowControlCount(_ node: Node) -> Int {
    let roles: Set<String> = [
        "AXButton", "AXRadioButton", "AXCheckBox", "AXTextField", "AXHeading", "AXLink",
        "AXRow", "AXCell", "AXPopUpButton", "AXMenuButton", "AXStaticText", "AXWebArea",
        "AXOutline", "AXImage", "AXList",
    ]
    func walk(_ node: Node, inWindow: Bool) -> Int {
        let inside = inWindow || node.role == "AXWindow"
        var count = inside && node.role != "AXWindow" && roles.contains(node.role) ? 1 : 0
        for child in node.children {
            count += walk(child, inWindow: inside)
        }
        return count
    }
    return walk(node, inWindow: false)
}

func waitForTree(_ application: AXUIElement) -> Node? {
    var latest: Node?
    let calculator = targetAppName.caseInsensitiveCompare("calculator") == .orderedSame
    let deadline = Date().addingTimeInterval(40)
    repeat {
        latest = captureTree(application)
        if let tree = latest {
            if calculator && hasAllDigits(tree) {
                return tree
            }
            if !calculator && windowControlCount(tree) >= 8 {
                return tree
            }
        }
        Thread.sleep(forTimeInterval: 0.25)
    } while Date() < deadline
    return latest
}

func treeSignature(_ node: Node) -> String {
    let frame = "\(Int(node.frame.x.rounded())):\(Int(node.frame.y.rounded())):\(Int(node.frame.width.rounded())):\(Int(node.frame.height.rounded()))"
    let texts = node.texts.joined(separator: "\u{1f}")
    let children = node.children.map(treeSignature).joined(separator: "\u{1e}")
    return "\(node.role)\u{1d}\(frame)\u{1d}\(texts)\u{1d}\(children)"
}

func publish(_ snapshot: Snapshot, wait: Bool = false) {
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
    let done = DispatchSemaphore(value: 0)
    let outcome = PublishOutcome()
    session.dataTask(with: request) { _, response, error in
        if let error = error {
            fputs("publish failed: \(error.localizedDescription)\n", stderr)
            outcome.failed = true
        } else if let http = response as? HTTPURLResponse, http.statusCode != 202 {
            fputs("publish status \(http.statusCode)\n", stderr)
            outcome.failed = true
        }
        session.finishTasksAndInvalidate()
        done.signal()
    }.resume()
    if wait {
        _ = done.wait(timeout: .now() + 3)
        if outcome.failed {
            exit(1)
        }
    }
}

final class PublishOutcome {
    var failed = false
}

func captureChangedTree(_ application: AXUIElement, previous: String) -> Node? {
    var latest: Node?
    let deadline = Date().addingTimeInterval(5)
    repeat {
        if let tree = captureTree(application) {
            latest = tree
            if treeSignature(tree) != previous {
                return tree
            }
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    return latest
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
    fputs("usage: gui-reader apps | gui-reader <targetApp> <outputDir> [watch | perform <nodeId>]\n", stderr)
    exit(64)
}

let targetApp = arguments[1]
targetAppName = targetApp
let outputDir = URL(fileURLWithPath: arguments[2], isDirectory: true)
var watch = false
var performID: String?
if arguments.count >= 4 {
    if arguments[3] == "watch" && arguments.count == 4 {
        watch = true
    } else if arguments[3] == "perform", arguments.count == 5, !arguments[4].isEmpty {
        performID = arguments[4]
    } else {
        fputs("usage: gui-reader apps | gui-reader <targetApp> <outputDir> [watch | perform <nodeId>]\n", stderr)
        exit(64)
    }
}

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
AXUIElementSetMessagingTimeout(application, 5)
_ = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
_ = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

guard let tree = waitForTree(application) else {
    fputs("read produced no tree\n", stderr)
    exit(1)
}

let appName = running.localizedName ?? targetApp

if let nodeID = performID {
    guard let element = findElement(application, id: "0", target: nodeID, depth: 0) else {
        fputs("no node \(nodeID)\n", stderr)
        exit(1)
    }
    performClick(element, nodeID: nodeID)
    guard let updated = captureChangedTree(application, previous: treeSignature(tree)) else {
        fputs("read produced no tree after click\n", stderr)
        exit(1)
    }
    let performed = Snapshot(app: appName, capturedAt: isoTimestamp(), tree: updated)
    do {
        try writeSnapshot(performed, to: outputDir)
    } catch {
        fputs("failed to write snapshot: \(error)\n", stderr)
        exit(1)
    }
    publish(performed, wait: true)
    fputs("performed click \(nodeID)\n", stderr)
    exit(0)
}

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
