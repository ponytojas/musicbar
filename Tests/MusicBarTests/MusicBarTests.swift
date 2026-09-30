import SwiftUI
import XCTest
@testable import MusicBar

@MainActor
final class MusicBarTests: XCTestCase {
    func testPlayingPlayerWinsOverPausedActivePlayer() {
        let paused = MusicController.Candidate(
            player: .appleMusic,
            nowPlaying: .init(title: "Paused", artist: "Artist", isPlaying: false)
        )
        let playing = MusicController.Candidate(
            player: .spotify,
            nowPlaying: .init(title: "Playing", artist: "Artist", isPlaying: true)
        )

        let selected = MusicController.preferredCandidate(
            from: [paused, playing],
            activePlayer: .appleMusic
        )

        XCTAssertEqual(selected?.player, .spotify)
        XCTAssertEqual(selected?.nowPlaying.title, "Playing")
    }

    func testActivePlayerWinsWhenBothPlayersArePaused() {
        let spotify = MusicController.Candidate(
            player: .spotify,
            nowPlaying: .init(title: "Spotify", artist: "Artist", isPlaying: false)
        )
        let music = MusicController.Candidate(
            player: .appleMusic,
            nowPlaying: .init(title: "Music", artist: "Artist", isPlaying: false)
        )

        let selected = MusicController.preferredCandidate(
            from: [spotify, music],
            activePlayer: .appleMusic
        )

        XCTAssertEqual(selected?.player, .appleMusic)
    }

    func testLegacyEqualizerColorModesMigrate() {
        XCTAssertEqual(EqualizerColorMode(storedValue: "system"), .gradient)
        XCTAssertEqual(EqualizerColorMode(storedValue: "custom"), .fixed)
        XCTAssertEqual(EqualizerColorMode(storedValue: "rainbow"), .random)
    }

    func testWaveformLevelMappingClampsAndPreservesDynamicRange() {
        XCTAssertEqual(WaveformMath.normalizedLevel(rms: 0), 0)
        XCTAssertEqual(WaveformMath.normalizedLevel(rms: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(WaveformMath.normalizedLevel(rms: 2), 1)

        let quiet = WaveformMath.normalizedLevel(rms: 0.01)
        let loud = WaveformMath.normalizedLevel(rms: 0.25)
        XCTAssertGreaterThan(quiet, 0)
        XCTAssertGreaterThan(loud, quiet)
        XCTAssertLessThan(loud, 1)
    }

    func testWaveformDisplayContrastIsExpandedAndClamped() {
        let input: [CGFloat] = [0.68, 0.70, 0.72]
        let output = WaveformMath.displayLevels(from: input)

        XCTAssertEqual(output.count, input.count)
        XCTAssertGreaterThan(output[2] - output[0], input[2] - input[0])
        XCTAssertTrue(output.allSatisfy { (0...1).contains($0) })
        XCTAssertEqual(WaveformMath.displayLevels(from: [0, 0]), [0, 0])
    }

    func testNowPlayingParsing() {
        XCTAssertEqual(
            MusicController.parseNowPlaying("Song\nArtist\nplaying"),
            .init(title: "Song", artist: "Artist", isPlaying: true)
        )
        XCTAssertEqual(
            MusicController.parseNowPlaying("Two\nLines\n\npaused"),
            .init(title: "Two\nLines", artist: "", isPlaying: false)
        )
        XCTAssertNil(MusicController.parseNowPlaying("Song\nArtist"))
    }

    func testHexColorRoundTrip() {
        XCTAssertEqual(Color(hex: "#FF375F").hexString, "#FF375F")
        XCTAssertEqual(Color(hex: "0A0B0C").hexString, "#0A0B0C")
    }

    func testSearchResultMustMatchArtist() {
        let results: [[String: Any]] = [
            ["artistName": "Tribute Band", "trackName": "Song"],
            ["artistName": "The Artist & Friend", "trackName": "Song"],
        ]
        let match = MusicController.searchResult(in: results, matchingArtist: "the artist")
        XCTAssertEqual(match?["artistName"] as? String, "The Artist & Friend")
        XCTAssertNil(MusicController.searchResult(in: results, matchingArtist: "Nobody"))
        XCTAssertEqual(MusicController.searchResult(in: results, matchingArtist: "")?["artistName"] as? String, "Tribute Band")
    }
}
