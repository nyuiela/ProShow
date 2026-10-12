import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    var document: DeviceSettingsDocument
    private let url: URL

    init(url: URL? = nil) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = folder.appendingPathComponent("ProShow", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.url = url ?? root.appendingPathComponent("device-settings.json")
        if let data = try? Data(contentsOf: self.url),
           let decoded = try? ProjectJSON.decoder.decode(DeviceSettingsDocument.self, from: data)
        {
            document = decoded
        } else {
            document = .default
        }
    }

    func save() {
        guard let data = try? ProjectJSON.encoder.encode(document) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Factory device settings plus UserDefaults desk prefs and runtime caches.
    func resetToFactoryDefaults() {
        document = .default
        save()
        UserSettingsStore.shared.resetToDefaults()
    }

    func upsert(_ account: StreamAccount, secret: String?) {
        if let index = document.accounts.firstIndex(where: { $0.id == account.id }) {
            document.accounts[index] = account
        } else {
            document.accounts.append(account)
        }
        if let secret, !secret.isEmpty {
            _ = KeychainStreamVault.save(identifier: account.keychainStreamKeyIdentifier, secret: secret)
            if let index = document.accounts.firstIndex(where: { $0.id == account.id }) {
                document.accounts[index].isAuthenticated = true
                document.accounts[index].lastAuthenticated = Date()
            }
        }
        save()
    }

    func removeAccount(_ id: UUID) {
        if let account = document.accounts.first(where: { $0.id == id }) {
            StreamAccountManager.shared.deleteTokens(for: account)
        }
        document.accounts.removeAll { $0.id == id }
        save()
    }

    func applyAppearance() {
        #if os(macOS)
        importAppKitAppearance()
        #endif
    }

    #if os(macOS)
    private func importAppKitAppearance() {
        switch document.appearance {
        case .system: NSAppOverride.appearance = nil
        case .dark: NSAppOverride.appearance = NSAppOverride.dark
        case .light: NSAppOverride.appearance = NSAppOverride.light
        }
    }
    #endif
}

#if os(macOS)
import AppKit

private enum NSAppOverride {
    static var appearance: NSAppearance? {
        get { NSApp.appearance }
        set { NSApp.appearance = newValue }
    }

    static let dark = NSAppearance(named: .darkAqua)
    static let light = NSAppearance(named: .aqua)
}
#endif
