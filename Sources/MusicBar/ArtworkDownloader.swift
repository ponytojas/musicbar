import Foundation

/// Network side of the artwork pipeline: https only, known image hosts only,
/// and never more than the stated number of bytes in memory.
enum ArtworkDownloader {
    static let maximumArtworkBytes = 20 * 1_024 * 1_024
    static let maximumSearchResponseBytes = 1 * 1_024 * 1_024

    /// Spotify's and Apple's image CDNs. Cover URLs come from the player or
    /// from a search response, so anything else is refused.
    private static let artworkHostSuffixes = ["scdn.co", "spotifycdn.com", "mzstatic.com"]

    static func isTrustedArtworkURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return artworkHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Downloads at most `maximumBytes`. The body is read as a stream, so a
    /// larger or mislabeled response is dropped mid-transfer instead of
    /// being buffered whole first.
    nonisolated static func data(
        from url: URL,
        maximumBytes: Int,
        requiredMIMEPrefix: String? = nil
    ) async -> Data? {
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  response.expectedContentLength <= Int64(maximumBytes)
            else { return nil }
            if let requiredMIMEPrefix {
                guard let mimeType = response.mimeType, mimeType.hasPrefix(requiredMIMEPrefix) else { return nil }
            }
            var data = Data()
            if response.expectedContentLength > 0 {
                data.reserveCapacity(Int(response.expectedContentLength))
            }
            for try await byte in bytes {
                data.append(byte)
                // Leaving the loop cancels the rest of the transfer.
                if data.count > maximumBytes { return nil }
            }
            return data
        } catch {
            return nil
        }
    }
}
