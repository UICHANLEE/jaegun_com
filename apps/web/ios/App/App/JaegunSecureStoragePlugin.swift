import Capacitor
import Foundation
import Security

@objc(JaegunSecureStoragePlugin)
final class JaegunSecureStoragePlugin: CAPPlugin, CAPBridgedPlugin {
    let identifier = "JaegunSecureStoragePlugin"
    let jsName = "JaegunSecureStorage"
    let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "prepare", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "get", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "set", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "remove", returnType: CAPPluginReturnPromise)
    ]

    private enum StorageError: Error {
        case invalidKey
        case invalidValue
        case invalidEncoding
        case keychain(OSStatus)
    }

    private static let authStorageKey = "sb-opwzujhfsxqaivtbjewg-auth-token"
    private static let passwordRecoveryIntentKey = "com.uichanlee.jaegun.password-recovery-intent.v1"
    private static let fixedAllowedKeys: Set<String> = [
        authStorageKey,
        "\(authStorageKey)-user",
        "\(authStorageKey)-code-verifier",
        "\(authStorageKey)-flows-code-verifier",
        passwordRecoveryIntentKey
    ]
    private static let flowKeyPrefix = "\(authStorageKey)-flow-"
    private static let flowKeySuffix = "-code-verifier"
    private static let allowedFlowIDCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
    )
    private static let maximumValueByteCount = 1_048_576
    private static let installMarkerDefaultsKey = "com.uichanlee.jaegun.secure-storage.install-marker.v1"
    private static let installationIdentifierDefaultsKey = "com.uichanlee.jaegun.installation-identifier.v1"
    private static let keychainProbeAccount = "__jaegun_keychain_probe_v1__"

    private let storageQueue = DispatchQueue(label: "com.uichanlee.jaegun.secure-storage")
    private var isPrepared = false
    private var installationIdentifier: String?

    private var keychainService: String {
        "\(Bundle.main.bundleIdentifier ?? "com.uichanlee.jaegun").supabase-auth"
    }

    @objc func prepare(_ call: CAPPluginCall) {
        storageQueue.async {
            do {
                try self.ensurePrepared()
                self.resolve(call)
            } catch {
                self.rejectUnavailable(call)
            }
        }
    }

    @objc func get(_ call: CAPPluginCall) {
        guard let key = call.getString("key"), isAllowedStorageKey(key) else {
            call.reject("허용되지 않은 인증 저장소 키입니다.", "INVALID_STORAGE_KEY")
            return
        }

        storageQueue.async {
            do {
                try self.ensurePrepared()
                let value = try self.readValue(for: key)
                self.resolve(call, data: ["value": value ?? NSNull()])
            } catch {
                self.rejectUnavailable(call)
            }
        }
    }

    @objc func set(_ call: CAPPluginCall) {
        guard let key = call.getString("key"), isAllowedStorageKey(key) else {
            call.reject("허용되지 않은 인증 저장소 키입니다.", "INVALID_STORAGE_KEY")
            return
        }
        guard let value = call.getString("value"),
              let data = value.data(using: .utf8),
              data.count <= Self.maximumValueByteCount else {
            call.reject("인증 저장소 값이 올바르지 않습니다.", "INVALID_STORAGE_VALUE")
            return
        }

        storageQueue.async {
            do {
                try self.ensurePrepared()
                try self.writeValue(data, for: key)
                self.resolve(call)
            } catch {
                self.rejectUnavailable(call)
            }
        }
    }

    @objc func remove(_ call: CAPPluginCall) {
        guard let key = call.getString("key"), isAllowedStorageKey(key) else {
            call.reject("허용되지 않은 인증 저장소 키입니다.", "INVALID_STORAGE_KEY")
            return
        }

        storageQueue.async {
            do {
                try self.ensurePrepared()
                try self.deleteValue(for: key)
                self.resolve(call)
            } catch {
                self.rejectUnavailable(call)
            }
        }
    }

    private func isAllowedStorageKey(_ key: String) -> Bool {
        if Self.fixedAllowedKeys.contains(key) {
            return true
        }
        guard key.hasPrefix(Self.flowKeyPrefix), key.hasSuffix(Self.flowKeySuffix) else {
            return false
        }

        let flowStart = key.index(key.startIndex, offsetBy: Self.flowKeyPrefix.count)
        let flowEnd = key.index(key.endIndex, offsetBy: -Self.flowKeySuffix.count)
        guard flowStart <= flowEnd else { return false }
        let flowID = String(key[flowStart..<flowEnd])
        guard (8...64).contains(flowID.count),
              flowID.unicodeScalars.allSatisfy({ Self.allowedFlowIDCharacters.contains($0) }) else {
            return false
        }
        return true
    }

    private func ensurePrepared() throws {
        guard !isPrepared else { return }

        let defaults = UserDefaults.standard
        let marker = defaults.string(forKey: Self.installMarkerDefaultsKey)
        let storedIdentifier = defaults.string(forKey: Self.installationIdentifierDefaultsKey)
        let hasValidInstallation = marker == storedIdentifier
            && storedIdentifier.flatMap(UUID.init(uuidString:)) != nil

        if hasValidInstallation, let storedIdentifier {
            installationIdentifier = storedIdentifier.lowercased()
        } else {
            // Keychain items can outlive an app uninstall. Missing or inconsistent
            // app-container markers therefore invalidate every old auth credential.
            try deleteAllValues()
            let newIdentifier = UUID().uuidString.lowercased()
            defaults.set(newIdentifier, forKey: Self.installationIdentifierDefaultsKey)
            defaults.set(newIdentifier, forKey: Self.installMarkerDefaultsKey)
            installationIdentifier = newIdentifier
        }

        try verifyKeychainAvailability()
        isPrepared = true
    }

    private func baseQuery(account: String? = nil) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain: true
        ]
        if let account {
            query[kSecAttrAccount] = account
        }
        return query
    }

    private func readData(for account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StorageError.keychain(status) }
        guard let data = result as? Data else { throw StorageError.invalidEncoding }
        return data
    }

    private func readValue(for key: String) throws -> String? {
        guard let data = try readData(for: key) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw StorageError.invalidEncoding
        }
        return value
    }

    private func writeValue(_ data: Data, for account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw StorageError.keychain(updateStatus)
        }

        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw StorageError.keychain(addStatus) }
    }

    private func deleteValue(for account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StorageError.keychain(status)
        }
    }

    private func deleteAllValues() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StorageError.keychain(status)
        }
    }

    private func verifyKeychainAvailability() throws {
        let probe = Data(UUID().uuidString.utf8)
        try? deleteValue(for: Self.keychainProbeAccount)
        do {
            try writeValue(probe, for: Self.keychainProbeAccount)
            guard try readData(for: Self.keychainProbeAccount) == probe else {
                throw StorageError.invalidValue
            }
            try deleteValue(for: Self.keychainProbeAccount)
        } catch {
            try? deleteValue(for: Self.keychainProbeAccount)
            throw error
        }
    }

    private func resolve(_ call: CAPPluginCall, data: JSObject? = nil) {
        DispatchQueue.main.async {
            if let data {
                call.resolve(data)
            } else {
                call.resolve()
            }
        }
    }

    private func rejectUnavailable(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            // Do not include Keychain status, keys, or stored values in JS errors or logs.
            call.reject("안전한 인증 저장소를 사용할 수 없습니다.", "SECURE_STORAGE_UNAVAILABLE")
        }
    }
}
