import AppKit
import Synchronization

private struct ChromeTab: Decodable {
    let window: String
    let id: String
    let title: String
    let url: String
}

struct OpenWindow: @unchecked Sendable {
    let pid: pid_t
    let id: CGWindowID
    let element: AXUIElement
    let title: String
    let tabs: [(element: AXUIElement, title: String)]
}

private typealias CreateElement = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
private typealias MainConnection = @convention(c) () -> Int32
private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

private func symbol<T>(_ name: String, in library: String, as _: T.Type) -> T? {
    dlsym(dlopen(library, RTLD_LAZY), name).map { unsafeBitCast($0, to: T.self) }
}

private let accessibility = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
private let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
private let createElement = symbol("_AXUIElementCreateWithRemoteToken", in: accessibility, as: CreateElement.self)
private let getWindow = symbol("_AXUIElementGetWindow", in: accessibility, as: GetWindow.self)
private let mainConnection = symbol("SLSMainConnectionID", in: skyLight, as: MainConnection.self)
private let copySpaces = symbol("SLSCopySpacesForWindows", in: skyLight, as: CopySpaces.self)
private typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
private typealias PostEventRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
private let processForPID = symbol("GetProcessForPID", in: accessibility, as: ProcessForPID.self)
private let setFrontProcess = symbol("_SLPSSetFrontProcessWithOptions", in: skyLight, as: SetFrontProcess.self)
private let postEventRecord = symbol("SLPSPostEventRecordTo", in: skyLight, as: PostEventRecord.self)

@MainActor final class Switcher {
    private static let chromeID = "com.google.Chrome"
    private static let combeID = "com.samzong.combe"
    private nonisolated static let allSpaces: Int32 = 7
    private nonisolated static let scanBudget = Duration.milliseconds(50)
    private nonisolated static let scriptTimeout = 5.0

    private struct Target {
        let entry: Entry
        let app: String
        let focus: @MainActor () async -> Bool
    }

    private var targets: [Target] = []

    var entries: [Entry] {
        targets.map(\.entry)
    }

    func targets(of app: String) -> [Entry] {
        let owned = targets.filter { $0.app == app }
        return owned.count > 1 ? owned.map(\.entry) : []
    }

    nonisolated static func searchableWindows(_ windows: [OpenWindow]) -> [OpenWindow] {
        let counts = Dictionary(grouping: windows, by: \.pid).mapValues(\.count)
        return windows.filter { !$0.tabs.isEmpty || counts[$0.pid, default: 0] > 1 }
    }

    func focus(_ id: String) async -> Bool {
        guard let target = targets.first(where: { $0.entry.id == id }) else { return false }
        return await target.focus()
    }

    func reveal(app bundleID: String) -> Bool {
        guard AXIsProcessTrusted(),
              let pid = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })?.processIdentifier,
              let window = Self.windows(pid).first else { return false }
        return Self.raise(window)
    }

    private nonisolated static func windows(_ pid: pid_t) -> [OpenWindow] {
        scan(pid, ids: candidates([pid])[pid] ?? [], tabbed: false)
    }

    private static func raise(_ window: OpenWindow) -> Bool {
        var psn = ProcessSerialNumber()
        guard let processForPID, let setFrontProcess, let postEventRecord, processForPID(window.pid, &psn) == noErr,
              setFrontProcess(&psn, window.id, 0x200) == .success else { return false }
        for phase: UInt8 in [1, 2] {
            var event = [UInt8](repeating: 0, count: 0xF8)
            event[0x04] = 0xF8
            event[0x08] = phase
            event[0x3A] = 0x10
            withUnsafeBytes(of: window.id) { event.replaceSubrange(0x3C..<0x40, with: $0) }
            event.replaceSubrange(0x20..<0x30, with: repeatElement(0xFF, count: 0x10))
            _ = postEventRecord(&psn, &event)
        }
        AXUIElementSetMessagingTimeout(window.element, 0.2)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        return true
    }

    func reload(then changed: @escaping @MainActor () -> Void) {
        let apps = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != .current }
            .map { ($0.processIdentifier, $0) })
        let pids = Set(apps.keys)
        let combe = apps.values.first { $0.bundleIdentifier == Self.combeID }?.processIdentifier
        let chrome = apps.values.first { $0.bundleIdentifier == Self.chromeID }
        let trusted = AXIsProcessTrusted()
        Task {
            async let loaded = chrome == nil ? [] : Self.loadTabs()
            let found = trusted ? await Task.detached { Self.scan(pids, tabbed: combe) }.value : []
            let windows = Self.searchableWindows(found).flatMap { window -> [Target] in
                guard let app = apps[window.pid], let id = app.bundleIdentifier, let path = app.bundleURL?.path else { return [] }
                if !window.tabs.isEmpty {
                    return window.tabs.enumerated().map { index, tab in
                        let entry = Entry(id: "window:\(window.id):\(index)", name: tab.title, aliases: [], path: path, kind: .target)
                        return Target(entry: entry, app: id) { Self.focus(tab.element, in: window, of: app) }
                    }
                }
                let entry = Entry(id: "window:\(window.id)", name: window.title, aliases: [], path: path, kind: .target)
                return [Target(entry: entry, app: id) { Self.focus(window, of: app) }]
            }
            let tabs = await loaded.map { tab in
                let entry = Entry(id: "tab:\(tab.window):\(tab.id)", name: tab.title.isEmpty ? tab.url : tab.title,
                                  aliases: URL(string: tab.url)?.host().map { [$0] } ?? [],
                                  path: chrome?.bundleURL?.path ?? "", kind: .target)
                return Target(entry: entry, app: Self.chromeID) { await Self.focus(tab, of: chrome) }
            }
            targets = windows.filter { tabs.isEmpty || $0.app != Self.chromeID } + tabs
            changed()
        }
    }

    private nonisolated static func loadTabs() async -> [ChromeTab] {
        let data = await osascript("""
            const c = Application("\(chromeID)");
            const ids = c.windows.tabs.id(), titles = c.windows.tabs.title(), urls = c.windows.tabs.url();
            JSON.stringify(c.windows.id().flatMap((w, i) => ids[i].map((id, j) =>
                ({window: w, id, title: titles[i][j] || "", url: urls[i][j] || ""}))))
            """)
        return data.flatMap { try? JSONDecoder().decode([ChromeTab].self, from: $0) } ?? []
    }

    private static func focus(_ tab: ChromeTab, of app: NSRunningApplication?) async -> Bool {
        let data = await osascript("""
            const c = Application("\(chromeID)");
            const w = c.windows.byId(\(json(tab.window)));
            const i = w.tabs.id().indexOf(\(json(tab.id)));
            const titles = [w.activeTab().title()];
            if (i >= 0) { w.activeTabIndex = i + 1; w.index = 1; titles.push(w.activeTab().title()); }
            JSON.stringify(i >= 0 ? titles : null)
            """)
        guard let app, let titles = data.flatMap({ try? JSONDecoder().decode([String].self, from: $0) }) else { return false }
        if AXIsProcessTrusted(),
           let window = windows(app.processIdentifier).first(where: { window in titles.contains { !$0.isEmpty && window.title.hasPrefix($0) } }),
           raise(window) {
            return true
        }
        return app.activate()
    }

    private nonisolated static func json(_ value: String) -> String {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    private nonisolated static func osascript(_ script: String) async -> Data? {
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-l", "JavaScript", "-e", script]
                let output = Pipe()
                process.standardOutput = output
                guard (try? process.run()) != nil else { return done.resume(returning: nil) }
                let timeout = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + scriptTimeout, execute: timeout)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()
                done.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }

    private static func focus(_ tab: AXUIElement, in window: OpenWindow, of app: NSRunningApplication) -> Bool {
        AXUIElementSetMessagingTimeout(tab, 0.2)
        let pressed = AXUIElementPerformAction(tab, kAXPressAction as CFString)
        return [.success, .attributeUnsupported].contains(pressed) && focus(window, of: app)
    }

    private static func focus(_ window: OpenWindow, of app: NSRunningApplication) -> Bool {
        guard !app.isTerminated, windowID(window.element) == window.id else { return false }
        AXUIElementSetMessagingTimeout(window.element, 0.2)
        AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        return raise(window)
    }

    private nonisolated static func scan(_ pids: Set<pid_t>, tabbed: pid_t?) -> [OpenWindow] {
        let owners = Array(candidates(pids))
        let found = Mutex<[OpenWindow]>([])
        DispatchQueue.concurrentPerform(iterations: owners.count) { index in
            let pid = owners[index].key
            let windows = scan(pid, ids: owners[index].value, tabbed: pid == tabbed)
            found.withLock { $0 += windows }
        }
        return found.withLock { $0 }
    }

    private nonisolated static func scan(_ pid: pid_t, ids: [CGWindowID], tabbed: Bool) -> [OpenWindow] {
        var missing = Set(ids)
        var found: [CGWindowID: OpenWindow] = [:]
        func accept(_ element: AXUIElement) {
            AXUIElementSetMessagingTimeout(element, 0.1)
            guard let id = windowID(element), missing.contains(id),
                  attribute(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                  let title = attribute(element, kAXTitleAttribute) as? String, !trim(title).isEmpty else { return }
            missing.remove(id)
            found[id] = OpenWindow(pid: pid, id: id, element: element, title: title, tabs: tabbed ? tabs(of: element) : [])
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.forEach(accept)
        if let createElement {
            var token = Data(count: 20)
            token.withUnsafeMutableBytes {
                $0.storeBytes(of: UInt32(bitPattern: pid), toByteOffset: 0, as: UInt32.self)
                $0.storeBytes(of: 0x636F_636F, toByteOffset: 8, as: UInt32.self)
            }
            let deadline = ContinuousClock.now + scanBudget
            var element: UInt64 = 0
            while !missing.isEmpty, ContinuousClock.now < deadline {
                token.withUnsafeMutableBytes { $0.storeBytes(of: element, toByteOffset: 12, as: UInt64.self) }
                if let remote = createElement(token as CFData)?.takeRetainedValue() {
                    accept(remote)
                }
                element += 1
            }
        }
        return ids.compactMap { found[$0] }
    }

    private nonisolated static func tabs(of window: AXUIElement) -> [(element: AXUIElement, title: String)] {
        (attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            .filter { attribute($0, kAXRoleAttribute) as? String == kAXScrollAreaRole }
            .flatMap { attribute($0, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
            .compactMap { tab in
                guard attribute(tab, kAXRoleAttribute) as? String == kAXButtonRole, attribute(tab, kAXSelectedAttribute) != nil,
                      let title = attribute(tab, kAXDescriptionAttribute) as? String, !trim(title).isEmpty else { return nil }
                return (tab, title)
            }
    }

    private nonisolated static func candidates(_ pids: Set<pid_t>) -> [pid_t: [CGWindowID]] {
        let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        var owners: [pid_t: [CGWindowID]] = [:]
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  info[kCGWindowLayer as String] as? Int == 0,
                  info[kCGWindowAlpha as String] as? Double ?? 0 > 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID, onSpace(id) else { continue }
            owners[pid, default: []].append(id)
        }
        return owners
    }

    private nonisolated static func onSpace(_ id: CGWindowID) -> Bool {
        guard let mainConnection, let copySpaces else { return true }
        let spaces = copySpaces(mainConnection(), allSpaces, [NSNumber(value: id)] as CFArray)?.takeRetainedValue()
        return spaces.map { CFArrayGetCount($0) > 0 } ?? false
    }

    private nonisolated static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return getWindow?(element, &id) == .success && id != 0 ? id : nil
    }
}
