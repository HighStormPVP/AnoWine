//
//  ProxyProfileStore.swift
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

/// The app's proxy profiles, saved as JSON next to the runtime. Passwords go to
/// a ``ProxySecretStore`` (the Keychain in the app), never into the file.
@MainActor
public final class ProxyProfileStore: ObservableObject {
    public static let shared = ProxyProfileStore(
        fileURL: WhiskyWineInstaller.applicationFolder.appending(path: "ProxyProfiles.json"),
        secrets: KeychainProxySecretStore()
    )

    @Published public private(set) var profiles: [ProxyProfile]

    let fileURL: URL
    let secrets: ProxySecretStore

    public init(fileURL: URL, secrets: ProxySecretStore) {
        self.fileURL = fileURL
        self.secrets = secrets
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([ProxyProfile].self, from: data) {
            self.profiles = saved
        } else {
            self.profiles = []
        }
    }

    /// Adds the profile, or replaces the one with the same ID, and stores its password.
    public func save(_ profile: ProxyProfile, password: String?) throws {
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) {
            updated[index] = profile
        } else {
            updated.append(profile)
        }
        try write(updated)
        try secrets.setPassword(password, for: profile.id)
        profiles = updated
    }

    /// Removes the profile and its password.
    public func delete(id: UUID) throws {
        let updated = profiles.filter { $0.id != id }
        try write(updated)
        try secrets.setPassword(nil, for: id)
        profiles = updated
    }

    public func profile(id: UUID) -> ProxyProfile? {
        profiles.first { $0.id == id }
    }

    /// The stored password for a profile, for editing it.
    public func password(for id: UUID) -> String? {
        secrets.password(for: id)
    }

    private func write(_ profiles: [ProxyProfile]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: fileURL, options: .atomic)
    }
}
