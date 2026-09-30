import Foundation

enum Rank {
    static let limit = 8
    private static let frecencyWeight = 36.0
    private static let exact = 520.0
    private static let prefix = 240.0
    private static let wordPrefix = 150.0

    static func query(_ needle: String, apps: [Entry], history: History, now: Int64) -> [Entry] {
        let trimmed = trim(needle)
        guard !trimmed.isEmpty else { return [] }
        let target = Array(lowercase(trimmed).utf8)
        var scored: [(score: Double, key: [UInt8], order: Int, entry: Entry)] = []
        for (order, app) in apps.enumerated() {
            let bonus = ([app.name] + app.aliases + history.aliasesFor(app.id))
                .reduce(0.0) { Swift.max($0, nameBonus($1, target)) }
            guard bonus > 0 else { continue }
            let total = bonus + history.score(app.id, now: now) * frecencyWeight
            scored.append((total, Array(lowercase(app.name).utf8), order, app))
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.key != rhs.key {
                return lhs.key.lexicographicallyPrecedes(rhs.key)
            }
            return lhs.order < rhs.order
        }
        return scored.prefix(limit).map(\.entry)
    }

    private static func nameBonus(_ name: String, _ target: [UInt8]) -> Double {
        let lowered = lowercase(name)
        let bytes = Array(lowered.utf8)
        if bytes == target {
            return exact
        }
        if bytes.starts(with: target) {
            return prefix
        }
        return lowered.unicodeScalars
            .split(whereSeparator: { !isAlphanumeric($0) })
            .contains { Array(String($0).utf8).starts(with: target) } ? wordPrefix : 0
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic
            || [.decimalNumber, .letterNumber, .otherNumber].contains(scalar.properties.generalCategory)
    }
}
