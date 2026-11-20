import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LibraryWallpaperCard: View {
    let item: WallpaperItem
    let isSelected: Bool
    let isActive: Bool
    let onSelect: () -> Void
    let onApply: () -> Void
    let onToggleFavorite: () -> Void
    let onDelete: () -> Void

    @ObservedObject private var thumbnailGenerator = WallpaperThumbnailGenerator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Color.primary.opacity(0.07)
                    if let img = thumbnailGenerator.thumbnails[item.id] {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        VStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(item.type.rawValue.uppercased())
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.secondary)
                        }
                        .onAppear {
                            thumbnailGenerator.requestThumbnail(for: item)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 128)
                .clipped()
                .cornerRadius(10)

                HStack(spacing: 6) {
                    if isActive {
                        Text("ACTIVE")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    Button(action: onToggleFavorite) {
                        Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 11))
                            .foregroundColor(item.isFavorite ? .pink : .white)
                            .padding(5)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(item.resolutionLabel ?? item.source.rawValue)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 6) {
                Button(action: onApply) {
                    Text(isActive ? "Active" : "Apply")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isActive ? .green : .accentColor)
                .controlSize(.small)

                if !item.isBuiltIn {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    func iconForType(_ type: WallpaperType) -> String {
        switch type {
        case .video: return "film"
        case .web: return "sparkles"
        case .url: return "globe"
        case .image: return "photo"
        }
    }
}
