// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Choose what to download for the Android emulator: which system image, and whether to add the pre-booted snapshot.
///
/// The images are whatever the dependencies release holds (GuestCatalog), so a newly published one appears here without an
/// app update. The snapshot is offered only with images it can restore onto.
struct GuestDownloadPicker: View {
    @ObservedObject private var guest = GuestImage.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected: GuestImageOption?
    @State private var withSnapshot = GuestImage.wantsSnapshot
    @State private var loading = true

    private var catalog: GuestCatalog? { guest.catalog }

    var body: some View {
        NavigationStack {
            HuskPageList {
                if loading && catalog == nil {
                    Section {
                        HStack(spacing: 12) { ProgressView(); Text("Looking up the published images…").foregroundStyle(.secondary) }
                    }
                } else if let catalog, !catalog.images.isEmpty {
                    Section {
                        ForEach(catalog.images) { option in
                            Button { selected = option } label: { row(option) }
                                .buttonStyle(.plain)
                        }
                    } header: {
                        Text("System image")
                    } footer: {
                        Text("Every image runs the same Husk features. Newer images carry fixes; older ones are smaller downloads.")
                    }

                    if let image = selected ?? catalog.recommended {
                        Section {
                            Toggle(isOn: $withSnapshot) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Pre-booted snapshot").font(.body.weight(.medium))
                                    Text(snapshotLine(catalog)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!catalog.snapshotFits(image))
                        } header: {
                            Text("Start-up")
                        } footer: {
                            Text(catalog.snapshotFits(image)
                                 ? "With the snapshot Android opens in seconds. Without it the first start boots Android from cold, which takes five to twelve minutes."
                                 : "The snapshot was saved on a newer image and cannot be restored onto this one.")
                        }

                        Section {
                            Button { start(image, catalog) } label: {
                                Label("Download \(total(image, catalog))", systemImage: "arrow.down.circle.fill")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        } footer: {
                            Text("You can pause the download and resume it later, even after closing Husk. "
                               + "Free space now: \(free).")
                        }
                    }
                } else {
                    Section {
                        Label("The list of images could not be loaded. Check the connection and try again.",
                              systemImage: "wifi.exclamationmark")
                        Button("Try Again") { Task { await load() } }
                    }
                }
            }
            .navigationTitle("Download Android")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { await load() }
        }
    }

    private func row(_ option: GuestImageOption) -> some View {
        let isOn = (selected ?? catalog?.recommended) == option
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(isOn ? Theme.accent : Color.secondary.opacity(0.5))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("LineageOS · \(option.version)").font(.body.weight(.semibold))
                    if option.recommended { Tag(text: "Recommended", tint: Theme.accent) }
                }
                Text(option.summary).font(.caption).foregroundStyle(.secondary)
                Text(bytes(option.size) + (option.sha256 == nil ? "" : " · verified by checksum"))
                    .font(.technical(12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func snapshotLine(_ catalog: GuestCatalog) -> String {
        guard let snap = catalog.snapshot else { return "Not available right now" }
        return "\(bytes(snap.size)) more · \(snap.guestMiB) MB guest RAM, \(snap.xres)×\(snap.yres)"
    }

    private func total(_ image: GuestImageOption, _ catalog: GuestCatalog) -> String {
        let snap = withSnapshot && catalog.snapshotFits(image) ? (catalog.snapshot?.size ?? 0) : 0
        return bytes(image.size + snap)
    }

    private var free: String { Downloads.freeSpace().map(bytes) ?? "unknown" }

    private func load() async {
        loading = true
        await guest.loadCatalog()
        loading = false
        if let pinned = UserDefaults.standard.string(forKey: GuestImage.pinnedImageKey),
           let option = guest.catalog?.images.first(where: { $0.file == pinned }) {
            selected = option
        }
    }

    private func start(_ image: GuestImageOption, _ catalog: GuestCatalog) {
        // Claim the JIT region before the download: it takes a while, and StikDebug lets go by the end of it.
        JITBootstrap.prewarm()
        guest.download(image: image, withSnapshot: withSnapshot && catalog.snapshotFits(image))
        dismiss()
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}
