//
//  DistributionConfig.swift
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

public enum DistributionConfig {
    /// Where the runtime version feeds are served from: raw.githubusercontent.com
    /// rather than GitHub Pages, because some school and work networks block
    /// github.io while allowing GitHub itself. Same files as dist/pages/.
    static let feedBaseURL = "https://raw.githubusercontent.com/HighStormPVP/AnoWine/main/dist/pages"

    /// URL for the runtime version plist, which names the runtime to install
    /// and offers as an update.
    ///
    /// Each app line reads its own feed, so a runtime bump reaches only the
    /// apps built for it: Ano 6 and 7 read `WhiskyWineVersion.plist` (runtime
    /// 3.1.6) and Ano 8 reads `WhiskyWineVersion-v4.plist` (4.9.0). This app
    /// runs only the renamed engine (5.0.0 and later), whose feed is named like
    /// the version plist inside it.
    public static let versionPlistURL = "\(feedBaseURL)/\(AnoWineRuntime.versionPlistName).plist"

    /// The GitHub Releases page, which lists app releases and the runtime
    /// builds.
    public static let releasesPageURL = "https://github.com/HighStormPVP/AnoWine/releases"

    /// Base URL for GitHub Releases downloads
    public static let releasesBaseURL = "\(releasesPageURL)/download"

    /// Constructs the download URL for Wine Libraries from GitHub Releases
    /// - Parameter version: The version string (e.g., "2.5.0")
    /// - Returns: The full URL to download Libraries.tar.gz from GitHub Releases
    public static func librariesURL(version: String) -> String {
        "\(releasesBaseURL)/v\(version)/Libraries.tar.gz"
    }
}
