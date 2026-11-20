import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Covers kept on disk between launches, so a song heard before shows its
/// cover at once, offline included, without asking the player or the
/// network again. Each cover is stored scaled down, under a name that is a
/// hash of the song, and the least recently used go when the folder grows
/// past its limit. File work only: call it off the main thread.
enum ArtworkCache {
    static let maximumBytes = 50 * 1_024 * 1_024
    /// Enough for the card's cover at Retina scale.
    static let maximumPixelSize = 600

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.ponytojas.musicbar", isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
    }

    static func fileURL(for key: String, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("jpg")
    }

    /// The cover saved for `key`, marking it as just used.
    static func data(for key: String, in directory: URL) -> Data? {
        let url = fileURL(for: key, in: directory)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    /// Saves a scaled-down copy of `data` for `key`, then trims the folder.
    static func store(_ data: Data, for key: String, in directory: URL, limit: Int = maximumBytes) {
        guard let scaled = downscaled(data, maxPixelSize: maximumPixelSize) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try scaled.write(to: fileURL(for: key, in: directory), options: .atomic)
        } catch {
            return
        }
        prune(directory, limit: limit)
    }

    /// JPEG no larger than `maxPixelSize` on its long side; nil when `data`
    /// isn't an image.
    static func downscaled(_ data: Data, maxPixelSize: Int) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// Deletes the least recently used covers until the folder fits `limit`.
    static func prune(_ directory: URL, limit: Int) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)
        ) else { return }
        var entries = files.compactMap { url -> (url: URL, size: Int, used: Date)? in
            guard let values = try? url.resourceValues(forKeys: keys),
                  let size = values.fileSize,
                  let used = values.contentModificationDate
            else { return nil }
            return (url, size, used)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        entries.sort { $0.used < $1.used }
        for entry in entries where total > limit {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    static func clear(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}
