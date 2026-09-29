import AppKit
import CRime
import Carbon
import InputMethodKit

let rime: RimeApi_stdbool = {
    let path = Bundle.main.privateFrameworksPath! + "/librime.1.dylib"
    guard let library = dlopen(path, RTLD_NOW), let entry = dlsym(library, "rime_get_api_stdbool") else {
        fatalError(String(cString: dlerror()))
    }
    typealias Entry = @convention(c) () -> UnsafeMutablePointer<RimeApi_stdbool>
    return unsafeBitCast(entry, to: Entry.self)().pointee
}()

private func register(_ bundle: Bundle) {
    TISRegisterInputSource(bundle.bundleURL as CFURL)
    let filter = [kTISPropertyBundleID as String: bundle.bundleIdentifier!] as CFDictionary
    for source in TISCreateInputSourceList(filter, true).takeRetainedValue() as! [TISInputSource] {
        TISEnableInputSource(source)
    }
}

private func start(_ bundle: Bundle) {
    let user = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Launcher/rime")
    try? FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
    var traits = RimeTraits()
    traits.data_size = Int32(MemoryLayout<RimeTraits>.size - MemoryLayout<Int32>.size)
    traits.shared_data_dir = UnsafePointer(strdup(bundle.sharedSupportPath!))
    traits.user_data_dir = UnsafePointer(strdup(user.path))
    traits.app_name = UnsafePointer(strdup("rime.pinyin"))
    traits.min_log_level = 2
    rime.setup(&traits)
    rime.initialize(nil)
    _ = rime.start_maintenance(false)
}

@main
struct Main {
    @MainActor static func main() {
        let bundle = Bundle.main
        if CommandLine.arguments.contains("--register") {
            return register(bundle)
        }
        start(bundle)
        let server = IMKServer(name: bundle.infoDictionary?["InputMethodConnectionName"] as? String,
                               bundleIdentifier: bundle.bundleIdentifier)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(server) { app.run() }
    }
}
