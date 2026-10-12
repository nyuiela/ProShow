import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct NDISource: Hashable, Sendable {
    var name: String
    var url: String
}

/// Dynamic NDI 6 loader. Never linked at build time and never opened at process launch.
/// Set `hardwareEnabled` only after the operator opts into live I/O.
enum NDIRuntime {
    static var hardwareEnabled = false

    private static let lock = NSLock()
    private static var handle: UnsafeMutableRawPointer?
    private static var initialized = false

    static var isAvailable: Bool {
        libraryURL() != nil
    }

    static var shouldActivate: Bool {
        hardwareEnabled && isAvailable
    }

    static func libraryURL() -> URL? {
        let names = ["libndi.dylib", "libndi.6.dylib", "libndi.5.dylib"]
        var roots: [String] = []
        if let envDir = ProcessInfo.processInfo.environment["NDI_RUNTIME_DIR"], !envDir.isEmpty {
            roots.append(envDir)
        }
        roots.append(contentsOf: [
            "/Library/NDI SDK for Apple",
            "/Library/NDI Video SDK for Apple",
            "/usr/local/lib",
            "/opt/ndi/lib",
            "/opt/homebrew/lib",
        ])
        for root in roots {
            for folder in ["", "lib/macOS", "lib"] {
                let directory = folder.isEmpty
                    ? URL(fileURLWithPath: root, isDirectory: true)
                    : URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(folder, isDirectory: true)
                for name in names {
                    let url = directory.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: url.path) {
                        return url
                    }
                }
            }
        }
        return nil
    }

    @discardableResult
    static func load() -> Bool {
        #if canImport(Darwin)
        lock.lock()
        defer { lock.unlock() }
        if initialized { return handle != nil }
        guard let url = libraryURL() else { return false }
        handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL)
        guard let handle else { return false }
        typealias InitFn = @convention(c) () -> Bool
        guard let symbol = dlsym(handle, "NDIlib_initialize") else {
            dlclose(handle)
            self.handle = nil
            return false
        }
        let initialize = unsafeBitCast(symbol, to: InitFn.self)
        guard initialize() else {
            dlclose(handle)
            self.handle = nil
            return false
        }
        initialized = true
        return true
        #else
        return false
        #endif
    }

    static func version() -> String? {
        #if canImport(Darwin)
        guard load(), let handle, let symbol = dlsym(handle, "NDIlib_version") else { return nil }
        typealias VersionFn = @convention(c) () -> UnsafePointer<CChar>?
        let version = unsafeBitCast(symbol, to: VersionFn.self)
        guard let pointer = version() else { return nil }
        return String(cString: pointer)
        #else
        return nil
        #endif
    }

    static func findSources(timeoutMs: UInt32 = 200) -> [NDISource] {
        #if canImport(Darwin)
        guard load(), let handle else { return [] }
        typealias CreateFn = @convention(c) (UnsafeRawPointer?) -> OpaquePointer?
        typealias WaitFn = @convention(c) (OpaquePointer?, UInt32) -> Bool
        typealias SourcesFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt32>?) -> UnsafeRawPointer?
        typealias DestroyFn = @convention(c) (OpaquePointer?) -> Void
        guard
            let createSym = dlsym(handle, "NDIlib_find_create_v2"),
            let waitSym = dlsym(handle, "NDIlib_find_wait_for_sources"),
            let sourcesSym = dlsym(handle, "NDIlib_find_get_current_sources"),
            let destroySym = dlsym(handle, "NDIlib_find_destroy")
        else { return [] }
        let create = unsafeBitCast(createSym, to: CreateFn.self)
        let wait = unsafeBitCast(waitSym, to: WaitFn.self)
        let sources = unsafeBitCast(sourcesSym, to: SourcesFn.self)
        let destroy = unsafeBitCast(destroySym, to: DestroyFn.self)
        var settings = NDIFindCreate(show_local_sources: true, p_groups: nil, p_extra_ips: nil)
        let finder = withUnsafePointer(to: &settings) { create(UnsafeRawPointer($0)) }
        guard let finder else { return [] }
        defer { destroy(finder) }
        _ = wait(finder, timeoutMs)
        var count: UInt32 = 0
        guard let list = sources(finder, &count), count > 0 else { return [] }
        let records = list.bindMemory(to: NDISourceC.self, capacity: Int(count))
        return (0..<Int(count)).compactMap { index in
            let item = records[index]
            guard let name = item.p_ndi_name else { return nil }
            return NDISource(
                name: String(cString: name),
                url: item.p_url_address.map { String(cString: $0) } ?? ""
            )
        }
        #else
        return []
        #endif
    }

    static func connect(sourceName: String) -> Bool {
        findSources().contains { $0.name == sourceName || $0.url == sourceName }
    }

    static func resolvedSymbol(_ name: String) -> UnsafeMutableRawPointer? {
        #if canImport(Darwin)
        guard load(), let handle else { return nil }
        return dlsym(handle, name)
        #else
        _ = name
        return nil
        #endif
    }

    static func resetForTests() {
        hardwareEnabled = false
    }
}

private struct NDIFindCreate {
    var show_local_sources: Bool
    var p_groups: UnsafePointer<CChar>?
    var p_extra_ips: UnsafePointer<CChar>?
}

private struct NDISourceC {
    var p_ndi_name: UnsafePointer<CChar>?
    var p_url_address: UnsafePointer<CChar>?
}
