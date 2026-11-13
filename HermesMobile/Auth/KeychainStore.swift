import Foundation
import KeychainAccess
import UIKit

protocol KeychainStoring {
    func save(_ value: String, forKey key: KeychainStore.Key) throws
    func load(_ key: KeychainStore.Key) throws -> String?
    func delete(_ key: KeychainStore.Key) throws

    // Per-server-scoped variants (#16): the same logical key namespaced by a
    // stable server identifier (the normalized server URL), so secrets like the
    // custom request headers are stored separately per configured server and one
    // server's credentials are never read or cleared for another.
    func save(_ value: String, forKey key: KeychainStore.Key, scope: String) throws
    func load(_ key: KeychainStore.Key, scope: String) throws -> String?
    func delete(_ key: KeychainStore.Key, scope: String) throws
}

struct KeychainStore: KeychainStoring {
    enum Key: String {
        case serverURL = "server_url"
        // JSON-encoded [{name, value}] of user-supplied request headers (#255).
        // Values may be secrets, so the list lives in the Keychain, not defaults.
        case customHeaders = "custom_headers"
        // JSON-encoded multi-server registry (server list + active id). The server
        // URL is treated as a credential, so the registry
        // lives in the Keychain, not UserDefaults (#15).
        case servers = "servers"
        case botConnection = "bot_connection"
        // Per-server push pairing (relay URL, install key, preview key). Unlike
        // every other key here it lives in a shared Keychain access group so the
        // Notification Service Extension can read it; see `PushPairing.swift`.
        case pushPairing = "push_pairing"
        // Every webui server's persistent cookies, mirrored from `WebUICookieJar`.
        case webuiCookies = "webui_cookies"
    }

    private let keychain: Keychain

    init(service: String? = nil) {
        let service = service
            ?? Bundle.main.object(forInfoDictionaryKey: "HermesKeychainService") as? String
            ?? Bundle.main.bundleIdentifier
            ?? "com.uzairansar.hermesmobile"
        self.keychain = Keychain(service: service)
            .accessibility(.afterFirstUnlockThisDeviceOnly)
    }

    func save(_ value: String, forKey key: Key) throws {
        try keychain.set(value, key: key.rawValue)
    }

    func load(_ key: Key) throws -> String? {
        try keychain.get(key.rawValue)
    }

    func delete(_ key: Key) throws {
        try keychain.remove(key.rawValue)
    }

    func save(_ value: String, forKey key: Key, scope: String) throws {
        try keychain.set(value, key: Self.scopedKey(key, scope: scope))
    }

    func load(_ key: Key, scope: String) throws -> String? {
        try keychain.get(Self.scopedKey(key, scope: scope))
    }

    func delete(_ key: Key, scope: String) throws {
        try keychain.remove(Self.scopedKey(key, scope: scope))
    }

    /// Namespaces a logical key by a server scope. `::` can't appear in a key's
    /// raw value (they're lowercase identifiers), so it's an unambiguous separator
    /// and the legacy unscoped account (`custom_headers`) never collides with a
    /// scoped one (`custom_headers::https://host`).
    static func scopedKey(_ key: Key, scope: String) -> String {
        "\(key.rawValue)::\(scope)"
    }
}

/// The cookie jar every webui request and event stream uses, holding each server's
/// session cookie. It lives in memory and is mirrored to the Keychain (this device
/// only), so a sign-in survives relaunch without the cookie being written to
/// `Library/Cookies`, which backups include. An in-memory jar posts no change
/// notifications, so `AuthManager` calls `persist()` after a sign-in and after it
/// clears a server's cookies, and the jar saves itself whenever the app moves to the
/// background. Session-only cookies are never saved, matching the system jar.
final class WebUICookieJar: @unchecked Sendable {
    static let shared = WebUICookieJar(keychain: KeychainStore())

    let storage: HTTPCookieStorage
    private let keychain: KeychainStoring
    private let legacy: HTTPCookieStorage?
    private let lock = NSRecursiveLock()
    private var restored = false
    private var lastSaved: String?
    private var observer: NSObjectProtocol?

    /// `legacy` is the system jar earlier builds kept cookies in. The first restore
    /// that finds nothing saved moves its cookies here, so an update keeps the user
    /// signed in, and then deletes them from it.
    init(keychain: KeychainStoring, legacy: HTTPCookieStorage? = .shared) {
        self.keychain = keychain
        self.legacy = legacy
        storage = URLSessionConfiguration.ephemeral.httpCookieStorage ?? HTTPCookieStorage()
        storage.cookieAcceptPolicy = .always
        restore()
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.persist() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Loads the saved cookies once. Before the device's first unlock the Keychain
    /// can't be read; the jar then saves nothing, so the saved cookies are never
    /// overwritten, and the next restore or change tries again. A saved cookie never
    /// replaces one the jar already holds.
    func restore() {
        lock.lock(); defer { lock.unlock() }
        guard !restored else { return }
        let saved: String?
        do { saved = try keychain.load(.webuiCookies) } catch { return }
        let cookies = saved.map(Self.decode) ?? legacy?.cookies ?? []
        let held = Set((storage.cookies ?? []).map(Self.identity))
        for cookie in cookies where !held.contains(Self.identity(cookie)) {
            storage.setCookie(cookie)
        }
        restored = true
        lastSaved = saved
        persist()
        if saved == nil, lastSaved != nil, let legacy {
            cookies.forEach(legacy.deleteCookie)
        }
    }

    /// Mirrors the jar's persistent cookies to the Keychain, skipping an unchanged set.
    /// Restores first when the Keychain could not be read yet, and saves nothing while
    /// it still can't.
    func persist() {
        lock.lock(); defer { lock.unlock() }
        guard restored else { return restore() }
        let encoded = Self.encode(storage.cookies ?? [])
        guard encoded != lastSaved, (try? keychain.save(encoded, forKey: .webuiCookies)) != nil else { return }
        lastSaved = encoded
    }

    private static func identity(_ cookie: HTTPCookie) -> String {
        "\(cookie.name)\u{1F}\(cookie.domain)\u{1F}\(cookie.path)"
    }

    private static func encode(_ cookies: [HTTPCookie]) -> String {
        let now = Date()
        let saved = cookies
            .filter { !$0.isSessionOnly && ($0.expiresDate ?? .distantPast) > now }
            .sorted { identity($0) < identity($1) }
            .map { cookie in
                Dictionary(uniqueKeysWithValues: (cookie.properties ?? [:]).map { ($0.key.rawValue, $0.value) })
            }
        let data = (try? PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0)) ?? Data()
        return data.base64EncodedString()
    }

    private static func decode(_ text: String) -> [HTTPCookie] {
        guard let data = Data(base64Encoded: text),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return [] }
        return list.compactMap { properties in
            HTTPCookie(properties: Dictionary(uniqueKeysWithValues: properties.map { (HTTPCookiePropertyKey($0.key), $0.value) }))
        }
    }
}
