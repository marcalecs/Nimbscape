import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Discover section: HD catalog and local collection scanner.
extension MainWindowView {
    var discoverView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Discover Live Wallpapers")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Browse 1080p & 4K live wallpapers or scan a local folder of wallpaper packages.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Picker("", selection: $discoverTabMode) {
                    Text("HD Catalog").tag(0)
                    Text("Local Folder").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            if discoverTabMode == 0 {
                HDCatalogGridView(
                    onImportedAndApplied: { item in
                        selectedWallpaperID = item.id
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                localCollectionScannerView
            }
        }
        .padding(18)
    }

    var localCollectionScannerView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Local Folder Collection Scanner")
                    .font(.headline)
                Spacer()
                Button("Choose Folder...") {
                    chooseCollectionFolder()
                }
                .buttonStyle(.bordered)

                Button(action: { scanner.scan() }) {
                    Label(scanner.isScanning ? "Scanning..." : "Scan Folder", systemImage: "shippingbox")
                }
                .buttonStyle(.borderedProminent)
                .disabled(scanner.isScanning)
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundColor(.secondary)
                Text(preferences.collectionFolderPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let result = scanner.lastResult {
                    let newCount = result.candidates.filter { !$0.isAlreadyImported }.count
                    if newCount > 0 {
                        Button("Import All New (\(newCount))") {
                            scanner.importAllNew()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.small)
                    }
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(8)

            if let error = scanner.lastError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error.localizedDescription)
                        .font(.subheadline)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(10)
            } else if let result = scanner.lastResult {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if result.candidates.isEmpty {
                            Text("No compatible video, web, or image wallpaper packages found in this directory.")
                                .foregroundColor(.secondary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 300), spacing: 14)], spacing: 14) {
                                ForEach(result.candidates) { candidate in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(candidate.item.title)
                                            .font(.headline)
                                            .lineLimit(1)
                                        HStack {
                                            Text(candidate.item.type.rawValue.uppercased())
                                                .font(.caption2)
                                                .fontWeight(.bold)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.accentColor.opacity(0.15))
                                                .clipShape(Capsule())
                                            if let res = candidate.item.resolutionLabel {
                                                Text(res)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        HStack {
                                            Button(candidate.isAlreadyImported ? "Added" : "Import") {
                                                scanner.importCandidate(candidate, activate: false)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .disabled(candidate.isAlreadyImported)
                                            .controlSize(.small)

                                            if !candidate.isAlreadyImported {
                                                Button("Import & Apply") {
                                                    scanner.importCandidate(candidate, activate: true)
                                                }
                                                .buttonStyle(.bordered)
                                                .controlSize(.small)
                                            }
                                        }
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.primary.opacity(0.05))
                                    .cornerRadius(12)
                                }
                            }
                        }

                        if !result.skipped.isEmpty {
                            DisclosureGroup("Skipped Folders (\(result.skipped.count))") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(result.skipped) { skip in
                                        HStack(alignment: .top) {
                                            Text(skip.folderName)
                                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            Text("— \(skip.reason)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .padding(.top, 6)
                            }
                            .font(.subheadline)
                        }
                    }
                }
            } else {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 38))
                        .foregroundColor(.secondary)
                    Text("Click \"Scan Folder\" to detect local wallpaper packages.")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
        }
    }
}
