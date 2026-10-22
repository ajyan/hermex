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

    /// What a failed photo change tells him: a server without the photo route (404), else try again.
    nonisolated static func errorMessage(_ error: Error, removing: Bool) -> String {
        if case let APIError.http(statusCode, _) = error, statusCode == 404 {
            return "This server can't keep a photo of the week."
        }
        return removing ? "The photo wasn't removed. Try again." : "The photo didn't upload. Try again."
    }

    /// `data` decoded at most `maxPixel` on its long edge, upright, for a grid tile.
    nonisolated static func thumbnail(from data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Decoded week photos, per server, workspace session and path, so paging back to the cover (or
/// reopening it) doesn't fetch the file again and a photo never shows under another server or
/// workspace. A change to a photo drops its entries, since a new view or model starts again at version 0.
enum WeekPhotoCache {
    /// Costed in decoded bytes: a few full photos, or a year of grid thumbnails.
    static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    static func key(server: URL, sessionID: String?, path: String, thumbnail: Bool = false) -> NSString {
        "\(server.absoluteString)|\(sessionID ?? "")|\(path)\(thumbnail ? "|thumbnail" : "")" as NSString
    }

    static func invalidate(server: URL, sessionID: String?, path: String) {
        images.removeObject(forKey: key(server: server, sessionID: sessionID, path: path))
        images.removeObject(forKey: key(server: server, sessionID: sessionID, path: path, thumbnail: true))
    }

    static func store(_ image: UIImage, forKey key: NSString) {
        let pixels = (image.cgImage.map { $0.width * $0.height }) ?? Int(image.size.width * image.size.height * image.scale * image.scale)
        images.setObject(image, forKey: key, cost: pixels * 4)
    }
}

/// The cover's photo of the week, or a quiet placeholder while there is none (or it can't be read).
/// It loads through the view model, and reloads when the path or the upload version changes (an
/// upload clears its cache entry first).
struct WeekPhotoView: View {
    let viewModel: DailyDeckViewModel
    let palette: DeckPalette
    /// Whether a photo is showing, for the slot's VoiceOver value.
    @Binding var hasPhoto: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous)
            .fill(Color.clear)
            .aspectRatio(4 / 3, contentMode: .fit)
            .glowSurface(palette.colors, cornerRadius: HXRadius.lg)
            .overlay {
                WeekPhotoImage(server: viewModel.server, sessionID: viewModel.sessionID, path: viewModel.weekPhotoPath,
                               version: viewModel.weekPhotoVersion, hasPhoto: $hasPhoto,
                               load: { await viewModel.weekPhotoData(path: $0) }) {
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
    }
}

/// One week's photo filling its frame (the caller shapes and clips it), or `placeholder` until it
/// is ready or when it can't be read. It reads through `load`, keeps the decoded image in
/// `WeekPhotoCache`, and reloads when `path` or `version` changes. `thumbnailPixels` decodes a
/// small copy for grid tiles instead of the full photo.
struct WeekPhotoImage<Placeholder: View>: View {
    let server: URL
    let sessionID: String?
    let path: String
    let version: Int
    let thumbnailPixels: Int?
    @Binding var hasPhoto: Bool
    let load: @MainActor (String) async -> Data?
    let placeholder: Placeholder

    @State private var image: UIImage?
    /// The path `image` belongs to, so another week never shows this week's photo.
    @State private var imagePath: String?

    init(server: URL, sessionID: String?, path: String, version: Int = 0, thumbnailPixels: Int? = nil,
         hasPhoto: Binding<Bool> = .constant(false), load: @escaping @MainActor (String) async -> Data?,
         @ViewBuilder placeholder: () -> Placeholder) {
        self.server = server
        self.sessionID = sessionID
        self.path = path
        self.version = version
        self.thumbnailPixels = thumbnailPixels
        self._hasPhoto = hasPhoto
        self.load = load
        self.placeholder = placeholder()
    }

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipped()
            .task(id: "\(path)|\(version)") { await loadImage() }
            .onChange(of: image != nil) { _, showing in hasPhoto = showing }
    }

    /// A missing photo (404) and any other failure both leave the placeholder; a failed reload
    /// after an upload keeps the image already on screen.
    private func loadImage() async {
        if imagePath != path {
            image = nil
            imagePath = path
        }
        let key = WeekPhotoCache.key(server: server, sessionID: sessionID, path: path, thumbnail: thumbnailPixels != nil)
        if let cached = WeekPhotoCache.images.object(forKey: key) {
            image = cached
            return
        }
        guard let data = await load(path) else { return }
        let ready: UIImage?
        if let thumbnailPixels {
            ready = await Task.detached(priority: .utility) { WeekPhoto.thumbnail(from: data, maxPixel: thumbnailPixels) }.value
        } else if let decoded = UIImage(data: data) {
            ready = await decoded.byPreparingForDisplay() ?? decoded
        } else {
            ready = nil
        }
        guard let ready, !Task.isCancelled else { return }
        WeekPhotoCache.store(ready, forKey: key)
        image = ready
    }
}
