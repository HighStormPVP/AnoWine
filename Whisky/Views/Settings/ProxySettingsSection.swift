//
//  ProxySettingsSection.swift
//  Whisky
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

import SwiftUI
import WhiskyKit

/// Ano: the proxy clients bottles can send their traffic through.
struct ProxySettingsSection: View {
    @ObservedObject private var store = ProxyProfileStore.shared
    @State private var editing: ProxyProfile?
    @State private var testResults: [UUID: String] = [:]

    var body: some View {
        Section {
            ForEach(store.profiles) { profile in
                HStack {
                    VStack(alignment: .leading) {
                        Text(profile.name)
                        Text(verbatim: "\(kindName(profile.kind)) · \(profile.host):\(profile.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let result = testResults[profile.id] {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("settings.proxies.test") { test(profile) }
                    Button("settings.proxies.edit") { editing = profile }
                    Button("settings.proxies.delete", role: .destructive) {
                        try? store.delete(id: profile.id)
                    }
                }
            }
            Button("settings.proxies.add") { editing = ProxyProfile.newDefault() }
        } header: {
            Text("settings.proxies")
        } footer: {
            Text("settings.proxies.info")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { profile in
            ProxyProfileEditor(profile: profile, password: store.password(for: profile.id) ?? "") { saved, password in
                try? store.save(saved, password: password)
                restartBottles(using: saved.id)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
    }

    private func kindName(_ kind: ProxyKind) -> String {
        switch kind {
        case .socks5: String(localized: "proxy.kind.socks5")
        case .httpConnect: String(localized: "proxy.kind.http")
        }
    }

    private func test(_ profile: ProxyProfile) {
        guard let upstream = store.upstream(for: profile.id) else { return }
        testResults[profile.id] = "…"
        Task.detached {
            let result: String
            do {
                let address = try upstream.exitIP()
                result = String(format: String(localized: "settings.proxies.test.result"), address)
            } catch {
                result = String(format: String(localized: "settings.proxies.test.failed"), "\(error)")
            }
            await MainActor.run { testResults[profile.id] = result }
        }
    }

    /// Bottles whose helper is running keep the old profile until restarted.
    private func restartBottles(using profileID: UUID) {
        for bottle in BottleVM.shared.bottles where ProxyService.selection(of: bottle) == profileID {
            if ProxyService.shared.status(for: bottle) != nil {
                ProxyService.shared.restart(for: bottle)
            }
        }
    }
}

private struct ProxyProfileEditor: View {
    @State var profile: ProxyProfile
    @State var password: String
    @State private var portText: String = ""
    let onSave: (ProxyProfile, String?) -> Void
    let onCancel: () -> Void

    init(
        profile: ProxyProfile, password: String,
        onSave: @escaping (ProxyProfile, String?) -> Void, onCancel: @escaping () -> Void
    ) {
        self._profile = State(initialValue: profile)
        self._password = State(initialValue: password)
        self._portText = State(initialValue: String(profile.port))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        Form {
            TextField("proxy.name", text: $profile.name)
            Picker("proxy.kind", selection: $profile.kind) {
                Text("proxy.kind.socks5").tag(ProxyKind.socks5)
                Text("proxy.kind.http").tag(ProxyKind.httpConnect)
            }
            TextField("proxy.host", text: $profile.host)
            TextField("proxy.port", text: $portText)
            TextField("proxy.username", text: $profile.username)
            SecureField("proxy.password", text: $password)
            HStack {
                Spacer()
                Button("button.cancel", role: .cancel, action: onCancel)
                Button("proxy.save") {
                    var saved = profile
                    saved.port = UInt16(portText) ?? profile.port
                    onSave(saved, password.isEmpty ? nil : password)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.host.isEmpty || UInt16(portText) == nil)
            }
        }
        .padding()
        .frame(minWidth: 360)
    }
}
