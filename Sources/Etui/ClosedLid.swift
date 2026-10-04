import Foundation
import IOKit

enum ClosedLidState: Equatable {
    case unknown, checking, disabled, enabled, changing

    var busy: Bool {
        self == .checking || self == .changing
    }
}

enum SleepSettings {
    enum Failure: LocalizedError {
        case unreadable, command(String), verification

        var errorDescription: String? {
            switch self {
            case .unreadable: "Could not read the system sleep setting."
            case .command(let detail): detail
            case .verification: "macOS did not apply the requested sleep setting."
            }
        }
    }

    static func read() async throws -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { throw Failure.unreadable }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { throw Failure.unreadable }
        return value.boolValue
    }

    static func write(_ enabled: Bool) async throws -> Bool {
        let script = """
        try
            do shell script "/usr/bin/pmset -a disablesleep \(enabled ? 1 : 0)" with administrator privileges with prompt "Etui needs to change the system sleep setting."
            return "applied"
        on error number -128
            return "cancelled"
        end try
        """
        let result = try await run("/usr/bin/osascript", ["-e", script])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard result == "applied" || result == "cancelled" else { throw Failure.unreadable }
        return result == "applied"
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else { throw Failure.command(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return text
        }.value
    }
}

@MainActor final class ClosedLid {
    private(set) var state: ClosedLidState = .unknown {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?
    private let read: @Sendable () async throws -> Bool
    private let write: @Sendable (Bool) async throws -> Bool

    init(read: @escaping @Sendable () async throws -> Bool = SleepSettings.read,
         write: @escaping @Sendable (Bool) async throws -> Bool = SleepSettings.write) {
        self.read = read
        self.write = write
    }

    func refresh() async throws {
        guard !state.busy else { return }
        state = .checking
        do {
            state = try await read() ? .enabled : .disabled
        } catch {
            state = .unknown
            throw error
        }
    }

    func set(_ enabled: Bool) async throws {
        guard !state.busy else { return }
        state = .changing
        do {
            let applied = try await write(enabled)
            var observed = try await read()
            if applied {
                for _ in 0..<20 where observed != enabled {
                    try await Task.sleep(for: .milliseconds(100))
                    observed = try await read()
                }
            }
            state = observed ? .enabled : .disabled
            if applied && observed != enabled { throw SleepSettings.Failure.verification }
        } catch {
            if state == .changing {
                state = (try? await read()).map { $0 ? .enabled : .disabled } ?? .unknown
            }
            throw error
        }
    }
}
