import Foundation

enum Store {
    static func dataDir() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Etui")
    }

    static func now() -> Int64 {
        Int64(max(0, Date().timeIntervalSince1970))
    }

    static func read(_ dir: URL, _ name: String) -> Data? {
        try? Data(contentsOf: dir.appendingPathComponent(name))
    }

    static func hidden(_ dir: URL = dataDir()) -> Set<NSString> {
        guard let data = read(dir, "hidden.json"),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(ids.map { $0 as NSString })
    }

    @discardableResult
    static func write(_ dir: URL, _ name: String, _ data: Data) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            return true
        } catch {
            fputs("Etui: could not save \(name): \(error.localizedDescription)\n", stderr)
            return false
        }
    }
}

final class History {
    private struct Usage {
        var count: UInt64
        var lastUnix: Int64
    }

    private static let aliasFile = "aliases.json"
    private static let usageFile = "usage.json"
    private static let halfLifeDays = 14.0

    private let dataDir: URL?
    private var aliasMap: [NSString: String] = [:]
    private var usageMap: [NSString: Usage] = [:]

    init(dataDir: URL? = nil) {
        self.dataDir = dataDir
    }

    static func load(dataDir: URL = Store.dataDir()) -> History {
        let history = History(dataDir: dataDir)
        history.aliasMap = (object(dataDir, aliasFile) as? [NSString: String]) ?? [:]
        var usage: [NSString: Usage] = [:]
        if let apps = object(dataDir, usageFile)?["apps"] as? [NSString: Any] {
            for (key, value) in apps {
                guard let entry = value as? NSDictionary,
                      let count = plainInteger(entry["count"]).flatMap({ UInt64(exactly: $0) }),
                      let last = plainInteger(entry["last_unix"]).flatMap({ Int64(exactly: $0) })
                else {
                    usage = [:]
                    break
                }
                usage[key] = Usage(count: count, lastUnix: last)
            }
        }
        history.usageMap = usage
        return history
    }

    private static func object(_ dir: URL, _ name: String) -> NSDictionary? {
        guard let data = Store.read(dir, name),
              let parsed = jsonPreservingLeadingBOM(data)
        else { return nil }
        return parsed as? NSDictionary
    }

    private static func jsonPreservingLeadingBOM(_ data: Data) -> Any? {
        guard !data.starts(with: [0xEF, 0xBB, 0xBF]) else { return nil }
        var shielded: [UInt8] = []
        var quoted = false
        var escaped = false
        for byte in data {
            shielded.append(byte)
            if escaped {
                escaped = false
            } else if quoted, byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                quoted.toggle()
                if quoted {
                    shielded.append(0x20)
                }
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(shielded)) else { return nil }
        func restore(_ value: Any) -> Any {
            if let string = value as? NSString {
                return string.substring(from: 1) as NSString
            }
            if let array = value as? NSArray {
                return array.map(restore) as NSArray
            }
            guard let dictionary = value as? NSDictionary else { return value }
            let restored = NSMutableDictionary()
            for (key, value) in dictionary {
                restored[(key as! NSString).substring(from: 1) as NSString] = restore(value)
            }
            return restored
        }
        return restore(object)
    }

    func record(_ query: String, id: String) {
        if remember(query, id: id) {
            persist(Self.aliasFile, aliasMap as NSDictionary)
        }
        recordAt(id, now: Store.now())
        persist(Self.usageFile, ["apps": usageMap.mapValues { ["count": $0.count, "last_unix": $0.lastUnix] }] as NSDictionary)
    }

    @discardableResult
    func remember(_ query: String, id: String) -> Bool {
        let key = lowercase(trim(query))
        guard !key.isEmpty else { return false }
        aliasMap[key as NSString] = id
        return true
    }

    func recordAt(_ id: String, now: Int64) {
        var entry = usageMap[id as NSString] ?? Usage(count: 0, lastUnix: now)
        entry.count &+= 1
        entry.lastUnix = now
        usageMap[id as NSString] = entry
    }

    func score(_ id: String, now: Int64) -> Double {
        guard let entry = usageMap[id as NSString] else { return 0 }
        let days = max(Double(now &- entry.lastUnix) / 86400, 0)
        return log(1 + Double(entry.count)) * exp(-days / Self.halfLifeDays)
    }

    func aliasesFor(_ id: String) -> [String] {
        aliasMap.compactMap { sameBytes($0.value, id) ? $0.key as String : nil }
    }

    private func persist(_ name: String, _ stored: NSDictionary) {
        guard let dataDir,
              let data = try? JSONSerialization.data(withJSONObject: stored,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        Store.write(dataDir, name, data)
    }
}
