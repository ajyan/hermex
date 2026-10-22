import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Turns a picked photo into the small JPEG the server keeps for the week.
enum WeekPhoto {
    /// `data` as a JPEG whose long edge is at most `maxPixel` (never enlarged), upright, or nil
    /// when it is not an image. Photos from the library are often HEIC and several megabytes;
    /// the server accepts JPEG up to 4 MB.
    nonisolated static func jpeg(from data: Data, maxPixel: Int = 1600, quality: CGFloat = 0.8) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixel, max(width, height))
        ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

/// Decoded week photos, per server, workspace session and path, so paging back to the cover (or
/// reopening it) doesn't fetch the file again and a photo never shows under another server or
/// workspace. An upload drops its entry, since a new view model starts again at version 0.
enum WeekPhotoCache {
    static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        return cache
    }()

    static func key(server: URL, sessionID: String?, path: String) -> NSString {
        "\(server.absoluteString)|\(sessionID ?? "")|\(path)" as NSString
    }

    static func invalidate(server: URL, sessionID: String?, path: String) {
        images.removeObject(forKey: key(server: server, sessionID: sessionID, path: path))
    }
}

/// The week's photo, or a quiet placeholder while there is none (or it can't be read). It loads
/// through the view model, and reloads when the path or the upload version changes (an upload clears its cache entry first).
struct WeekPhotoView: View {
    let viewModel: DailyDeckViewModel
    let palette: DeckPalette
    /// Whether a photo is showing, for the slot's VoiceOver value.
    @Binding var hasPhoto: Bool

    @State private var image: UIImage?
    /// The path `image` belongs to, so another week never shows this week's photo.
    @State private var imagePath: String?

    private var loadID: String { "\(viewModel.weekPhotoPath)|\(viewModel.weekPhotoVersion)" }

    var body: some View {
        RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous)
            .fill(Color.clear)
            .aspectRatio(4 / 3, contentMode: .fit)
            .glowSurface(palette.colors, cornerRadius: HXRadius.lg)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(AppFont.title())
                        Text(verbatim: "Photo of the week")
                            .font(AppFont.subheadline(weight: .medium))
                        Text(verbatim: "Tap to add one")
                            .font(AppFont.footnote())
                    }
                    .foregroundStyle(palette.ink)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous))
            .task(id: loadID) { await load() }
            .onChange(of: image != nil) { _, showing in hasPhoto = showing }
    }

    /// A missing photo (404) and any other failure both leave the placeholder; a failed reload
    /// after an upload keeps the image already on screen.
    private func load() async {
        let path = viewModel.weekPhotoPath
        if imagePath != path {
            image = nil
            imagePath = path
        }
        let key = WeekPhotoCache.key(server: viewModel.server, sessionID: viewModel.sessionID, path: path)
        if let cached = WeekPhotoCache.images.object(forKey: key) {
            image = cached
            return
        }
        guard let data = await viewModel.weekPhotoData(path: path), let decoded = UIImage(data: data) else { return }
        let ready = await decoded.byPreparingForDisplay() ?? decoded
        guard !Task.isCancelled else { return }
        WeekPhotoCache.images.setObject(ready, forKey: key)
        image = ready
    }
}
