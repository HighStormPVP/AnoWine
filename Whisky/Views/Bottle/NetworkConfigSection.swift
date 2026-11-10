//
//  NetworkConfigSection.swift
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

/// Ano: which proxy profile, if any, the bottle's network goes through, with
/// what that does and doesn't cover yet.
struct NetworkConfigSection: View {
    @ObservedObject var bottle: Bottle
    @ObservedObject private var profiles = ProxyProfileStore.shared
    @ObservedObject private var service = ProxyService.shared
    @State private var pending: UUID??
    @State private var confirmRestart = false

    private var selection: Binding<UUID?> {
        Binding(
            get: { ProxyService.selection(of: bottle) },
            set: { request($0) }
        )
    }

    var body: some View {
        Section("config.network") {
            Picker("config.network.proxy", selection: selection) {
                Text("config.network.proxy.off").tag(UUID?.none)
                ForEach(profiles.profiles) { profile in
                    Text(profile.name).tag(UUID?.some(profile.id))
                }
            }
            .disabled(profiles.profiles.isEmpty && !bottle.settings.proxyEnabled)
            if profiles.profiles.isEmpty {
                Text("config.network.proxy.none")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if bottle.settings.proxyEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("config.network.proxy.udp")
                    Text("config.network.proxy.killswitch")
                    Text("config.network.proxy.winetricks")
                    status
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .alert("config.network.restart.title", isPresented: $confirmRestart) {
            Button("config.network.restart.confirm", role: .destructive) {
                // If the programs would not close, nothing changed: ask again.
                if let pending, service.apply(pending, to: bottle) == .stillRunning {
                    DispatchQueue.main.async { confirmRestart = true }
                } else {
                    pending = nil
                }
            }
            Button("button.cancel", role: .cancel) { pending = nil }
        } message: {
            Text("config.network.restart.message")
        }
    }

    @ViewBuilder private var status: some View {
        if let status = service.status(for: bottle) {
            Text(String(
                format: String(localized: "config.network.status.running"),
                Int(status.port), status.activeConnections
            ))
            if let error = status.lastError {
                Text(String(format: String(localized: "config.network.status.error"), error))
            }
        } else {
            Text("config.network.status.offline")
        }
    }

    /// Programs already running keep the old setting, so ask before closing them.
    private func request(_ profileID: UUID?) {
        guard profileID != ProxyService.selection(of: bottle) else { return }
        Task { @MainActor in
            if await Wine.isWineserverRunning(for: bottle) {
                pending = .some(profileID)
                confirmRestart = true
            } else {
                service.apply(profileID, to: bottle, stopBottle: { _ in }, isRunning: { _ in false })
            }
        }
    }
}
