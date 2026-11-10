//
//  ProxySecretStore.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation
import Security

/// Where proxy passwords are kept.
public protocol ProxySecretStore: Sendable {
    /// The password stored for a profile, if any.
    func password(for id: UUID) -> String?
    /// Stores a profile's password, or deletes it when `password` is `nil` or empty.
    func setPassword(_ password: String?, for id: UUID) throws
}

/// Keeps proxy passwords in the login Keychain, one generic password per profile.
public struct KeychainProxySecretStore: ProxySecretStore {
    public enum KeychainError: Error, Equatable {
        case status(OSStatus)
    }

    let service: String

    public init(service: String = "\(Bundle.whiskyBundleIdentifier).proxy") {
        self.service = service
    }

    private func query(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
    }

    public func password(for id: UUID) -> String? {
        var query = query(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    public func setPassword(_ password: String?, for id: UUID) throws {
        let deleted = SecItemDelete(query(for: id) as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            throw KeychainError.status(deleted)
        }
        guard let password, !password.isEmpty else { return }
        var item = query(for: id)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.status(added) }
    }
}
