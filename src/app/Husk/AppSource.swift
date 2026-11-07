import Foundation

// MARK: - Internal Model
struct AppSource: Identifiable, Equatable {
    let name: String
    let identifier: String
    var apps: [SourceApp]
    var id: String { identifier }
}

struct SourceApp: Identifiable, Equatable {
    let name: String
    let bundleIdentifier: String
    let version: String
    let downloadURL: String
    let iconURL: String
    let localizedDescription: String
    var id: String { bundleIdentifier }
}

// MARK: - F-Droid v1 Schema
private struct FDroidIndex: Codable {
    let repo: FDroidRepo
    let apps: [FDroidApp]
    let packages: [String: [FDroidPackage]]
}
private struct FDroidRepo: Codable { let name: String; let address: String }
private struct FDroidApp: Codable {
    let packageName: String
    let name: String?
    let summary: String?
    let description: String?
    let icon: String?
    let localized: [String: FDroidLocalized]?
}
private struct FDroidLocalized: Codable {
    let name: String?
    let summary: String?
    let description: String?
    let icon: String?
}
private struct FDroidPackage: Codable {
    let apkName: String
    let versionName: String?
    /// The ABIs of the APK's native code; nil for an APK with none, which runs anywhere.
    let nativecode: [String]?
}

// MARK: - Husk Simple Schema
private struct HuskSimpleSource: Codable {
    let name: String; let identifier: String; let apps: [SourceAppCodable]
}
private struct SourceAppCodable: Codable {
    let name, bundleIdentifier, version, downloadURL, iconURL, localizedDescription: String
}

// MARK: - Known repositories

/// A repository Discover knows about without being told.
struct KnownSource: Codable, Hashable, Identifiable {
    let name: String
    let url: String
    let description: String
    var id: String { url }
}

/// The repositories Discover adds by itself: a list kept in the repository (catalog/apk-sources.json), so a new one reaches
/// every install on its next launch, with a built-in copy for when that cannot be fetched.
enum KnownSources {
    static let listURL = URL(string: "https://raw.githubusercontent.com/WTeam-Files/Husk/main/catalog/apk-sources.json")!

    static let builtIn: [KnownSource] = [
        KnownSource(name: "F-Droid", url: "https://f-droid.org/repo/index-v1.json",
                    description: "The main catalogue of free and open-source Android apps."),
        KnownSource(name: "IzzyOnDroid", url: "https://apt.izzysoft.de/fdroid/repo/index-v1.json",
                    description: "Over a thousand open-source apps, often newer than F-Droid's builds."),
        KnownSource(name: "Husk Essentials", url: "https://raw.githubusercontent.com/WTeam-Files/Husk/main/catalog/source.json",
                    description: "App stores and essentials picked for Husk, such as F-Droid and Aurora Store."),
        KnownSource(name: "Guardian Project", url: "https://guardianproject.info/fdroid/repo/index-v1.json",
                    description: "Privacy and security apps: Orbot, Tor Browser and more."),
        KnownSource(name: "microG", url: "https://microg.org/fdroid/repo/index-v1.json",
                    description: "Open replacements for Google Play Services."),
        KnownSource(name: "NewPipe", url: "https://archive.newpipe.net/fdroid/repo/index-v1.json",
                    description: "The NewPipe video player, straight from its developers."),
        KnownSource(name: "Bitwarden", url: "https://mobileapp.bitwarden.com/fdroid/repo/index-v1.json",
                    description: "The Bitwarden password manager."),
        KnownSource(name: "Briar", url: "https://briarproject.org/fdroid/repo/index-v1.json",
                    description: "Briar, peer-to-peer messaging."),
        KnownSource(name: "Molly", url: "https://molly.im/fdroid/foss/fdroid/repo/index-v1.json",
                    description: "Molly, a hardened Signal client."),
        KnownSource(name: "Session", url: "https://fdroid.getsession.org/fdroid/repo/index-v1.json",
                    description: "Session, the onion-routed messenger."),
        KnownSource(name: "Threema", url: "https://releases.threema.ch/fdroid/repo/index-v1.json",
                    description: "Threema Libre."),
        KnownSource(name: "KDE", url: "https://cdn.kde.org/android/stable-releases/fdroid/repo/index-v1.json",
                    description: "KDE's Android apps, such as KDE Connect."),
        KnownSource(name: "LibRetro", url: "https://fdroid.libretro.com/repo/index-v1.json",
                    description: "RetroArch and its emulator cores."),
        KnownSource(name: "Metatrans Apps", url: "https://fdroid.metatransapps.com/fdroid/repo/index-v1.json",
                    description: "Chess and puzzle games."),
        KnownSource(name: "SpiritCroc", url: "https://s2.spiritcroc.de/fdroid/repo/index-v1.json",
                    description: "SchildiChat and other apps."),
        KnownSource(name: "PurpleI2P", url: "https://fdroid.i2pd.xyz/fdroid/repo/index-v1.json",
                    description: "The i2pd router."),
        KnownSource(name: "Monerujo", url: "https://f-droid.monerujo.io/fdroid/repo/index-v1.json",
                    description: "Monerujo, a Monero wallet."),
        KnownSource(name: "Cake Wallet", url: "https://fdroid.cakelabs.com/fdroid/repo/index-v1.json",
                    description: "Cake Wallet and Monero.com."),
        KnownSource(name: "Kali NetHunter", url: "https://store.nethunter.com/repo/index-v1.json",
                    description: "Kali NetHunter's security and network tools."),
    ]

    private struct List: Codable { let sources: [KnownSource] }

    static func fetch() async -> [KnownSource]? {
        var req = URLRequest(url: listURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode(List.self, from: data), !list.sources.isEmpty else { return nil }
        return list.sources
    }
}

// MARK: - Manager
@MainActor
final class SourceManager: ObservableObject {
    static let shared = SourceManager()

    @Published var sources: [AppSource] = []
    @Published var loadingSources: Set<String> = Set<String>()
    @Published var fetchErrors: [String: String] = [String: String]()
    @Published var downloadProgress: [String: Double] = [String: Double]()

    var isLoading: Bool { !loadingSources.isEmpty }

    @Published var sourceURLs: [String] = KnownSources.builtIn.map(\.url) {
        didSet {
            UserDefaults.standard.set(sourceURLs, forKey: "HuskSourceURLs")
        }
    }

    /// Every repository Discover knows about, for Add Source's suggestions.
    @Published private(set) var known: [KnownSource] = KnownSources.builtIn

    /// Known repositories already offered once. Each is added by itself the first time it is seen; one the person then
    /// removes stays removed.
    private static let offeredKey = "HuskSourcesOffered"

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 300
        return URLSession(configuration: cfg)
    }()

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "HuskSourceURLs"), !saved.isEmpty {
            sourceURLs = saved
        }
        adopt(KnownSources.builtIn)
    }

    /// Add every known repository not offered before, keeping the person's own order and removals.
    private func adopt(_ list: [KnownSource]) {
        let d = UserDefaults.standard
        var offered = Set(d.stringArray(forKey: Self.offeredKey) ?? [])
        // An install from before this list existed has offered nothing, but its own list is a choice too.
        if d.stringArray(forKey: Self.offeredKey) == nil, d.stringArray(forKey: "HuskSourceURLs") != nil {
            HuskLog.log("sources", "adding the known repositories to an existing list")
        }
        let new = list.filter { !offered.contains($0.url) && !sourceURLs.contains($0.url) }
        if !new.isEmpty {
            sourceURLs.append(contentsOf: new.map(\.url))
            HuskLog.log("sources", "added \(new.count) repositories: \(new.map(\.name).joined(separator: ", "))")
        }
        offered.formUnion(list.map(\.url))
        d.set(Array(offered), forKey: Self.offeredKey)
        var merged = known
        for k in list where !merged.contains(where: { $0.url == k.url }) { merged.append(k) }
        known = merged
    }

    /// Fetch everything (first appear / manual refresh): first the up-to-date list of known repositories, then every
    /// repository at once -- one at a time, a slow server held up all the rest.
    func fetchSources() async {
        if let list = await KnownSources.fetch() { adopt(list) }
        await withTaskGroup(of: Void.self) { group in
            for urlString in sourceURLs {
                group.addTask { await self.fetchSource(urlString: urlString) }
            }
        }
    }

    func isAdded(_ known: KnownSource) -> Bool { sourceURLs.contains(known.url) }

    // Add a new source and fetch ONLY that one
    func addSource(urlString: String) async {
        guard !sourceURLs.contains(urlString) else { return }
        sourceURLs.append(urlString)
        await fetchSource(urlString: urlString)
    }

    // Fetch a single source by URL
    func fetchSource(urlString: String) async {
        guard let url = URL(string: urlString) else {
            fetchErrors[urlString] = "Invalid URL"
            return
        }

        loadingSources.insert(urlString)
        fetchErrors.removeValue(forKey: urlString)

        defer { loadingSources.remove(urlString) }

        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                fetchErrors[urlString] = "HTTP \(http.statusCode)"
                return
            }
            // Parsed off the main thread: F-Droid's index alone is 35 MB of JSON, and decoding it here froze the screen.
            let parsed = await Task.detached(priority: .userInitiated) { Self.parse(data, identifier: urlString) }.value
            if let source = parsed {
                upsert(source: source)
            } else {
                fetchErrors[urlString] = "Unrecognized source format"
                HuskLog.log("sources", "Unrecognized format at \(urlString)")
            }
        } catch {
            fetchErrors[urlString] = error.localizedDescription
            HuskLog.log("sources", "Failed to fetch \(urlString): \(error)")
        }
    }

    /// The ABIs an app's native code may be built for to run in Husk's Android, best first.
    private nonisolated static let usableABIs = ["arm64-v8a", "armeabi-v7a", "armeabi"]

    /// An F-Droid index (v1) or a Husk source, as Discover's model.
    private nonisolated static func parse(_ data: Data, identifier: String) -> AppSource? {
        if let fdroid = try? JSONDecoder().decode(FDroidIndex.self, from: data) {
            let baseURL = fdroid.repo.address
            var apps: [SourceApp] = []
            for fApp in fdroid.apps {
                guard let pkgs = fdroid.packages[fApp.packageName], !pkgs.isEmpty else { continue }
                // Newest first in the index. Split APKs are one per ABI, and an x86 build installs and then cannot start,
                // so take the newest with no native code or with code for an ARM ABI.
                let runnable = pkgs.filter { p in p.nativecode.map { abis in abis.contains { usableABIs.contains($0) } } ?? true }
                guard let latest = runnable.first else { continue }
                let loc = fApp.localized?["en-US"] ?? fApp.localized?["en"] ?? fApp.localized?.values.first
                let appName = fApp.name ?? loc?.name ?? fApp.packageName
                let appSummary = fApp.summary ?? loc?.summary ?? fApp.description ?? loc?.description ?? ""
                // A top-level icon lives in icons/; a localized one beside the app's other store graphics.
                var iconURL = ""
                if let icon = fApp.icon {
                    iconURL = "\(baseURL)/icons/\(icon)"
                } else if let icon = loc?.icon {
                    let lang = fApp.localized?["en-US"] != nil ? "en-US" : (fApp.localized?.first { $0.value.icon == icon }?.key ?? "en-US")
                    iconURL = "\(baseURL)/\(fApp.packageName)/\(lang)/\(icon)"
                }
                apps.append(SourceApp(
                    name: appName,
                    bundleIdentifier: fApp.packageName,
                    version: latest.versionName ?? "",
                    downloadURL: "\(baseURL)/\(latest.apkName)",
                    iconURL: iconURL,
                    localizedDescription: appSummary
                ))
            }
            apps.sort { $0.name.lowercased() < $1.name.lowercased() }
            return AppSource(name: fdroid.repo.name, identifier: identifier, apps: apps)
        }
        if let simple = try? JSONDecoder().decode(HuskSimpleSource.self, from: data) {
            let apps = simple.apps.map {
                SourceApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier,
                          version: $0.version, downloadURL: $0.downloadURL,
                          iconURL: $0.iconURL, localizedDescription: $0.localizedDescription)
            }
            return AppSource(name: simple.name, identifier: identifier, apps: apps)
        }
        return nil
    }

    func removeSources(atOffsets offsets: IndexSet) {
        for url in offsets.map({ sourceURLs[$0] }) { removeSource(urlString: url) }
    }

    func removeSource(urlString: String) {
        sourceURLs.removeAll { $0 == urlString }
        sources.removeAll { $0.identifier == urlString }
        fetchErrors.removeValue(forKey: urlString)
    }

    private func upsert(source: AppSource) {
        if let idx = sources.firstIndex(where: { $0.identifier == source.identifier }) {
            sources[idx] = source
        } else {
            sources.append(source)
        }
    }

    // MARK: - APK Download + Install

    func downloadAndInstall(app: SourceApp) {
        guard let url = URL(string: app.downloadURL) else { return }
        downloadProgress[app.bundleIdentifier] = 0.01
        HuskLog.log("sources", "Downloading \(app.name)")

        let task = URLSession.shared.downloadTask(with: url) { localURL, _, error in
            Task { @MainActor in
                self.downloadProgress.removeValue(forKey: app.bundleIdentifier)
                guard let localURL, error == nil else {
                    HuskLog.log("sources", "Download failed: \(String(describing: error))")
                    return
                }
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let downloadDir = docs.appendingPathComponent("Downloaded_APKs")
                try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true, attributes: nil)
                let dest = downloadDir.appendingPathComponent("\(app.bundleIdentifier)-\(app.version).apk")
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.moveItem(at: localURL, to: dest)) != nil {
                    AndroidHost.shared.install([dest])
                }
            }
        }
        task.progress.observe(\.fractionCompleted) { progress, _ in
            Task { @MainActor in self.downloadProgress[app.bundleIdentifier] = progress.fractionCompleted }
        }
        task.resume()
    }
}
