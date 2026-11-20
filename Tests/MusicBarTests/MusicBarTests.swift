import Carbon.HIToolbox
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
            MusicController.parseNowPlaying("Song\nArtist\nAlbum\n0A1B2C3D4E5F6071\nplaying", from: .appleMusic),
            .init(title: "Song", artist: "Artist", album: "Album", trackID: "0A1B2C3D4E5F6071", isPlaying: true)
        )
        XCTAssertEqual(
            MusicController.parseNowPlaying("Two\nLines\n\n\nspotify:track:abc123\npaused", from: .spotify),
            .init(title: "Two\nLines", artist: "", album: "", trackID: "spotify:track:abc123", isPlaying: false)
        )
        // An ID in the wrong shape for its player is dropped, not trusted.
        XCTAssertNil(
            MusicController.parseNowPlaying("Song\nArtist\nAlbum\nspotify:track:abc\nplaying", from: .appleMusic)?.trackID
        )
        XCTAssertNil(MusicController.parseNowPlaying("Song\nArtist\nplaying", from: .appleMusic))
    }

    func testSpotifyWebURL() {
        XCTAssertEqual(
            MusicController.spotifyWebURL(fromURI: "spotify:track:4uLU6hMCjMI75M1A2tKUQC")?.absoluteString,
            "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"
        )
        XCTAssertNil(MusicController.spotifyWebURL(fromURI: "spotify:local:Artist:Album:Song:215"))
        XCTAssertNil(MusicController.spotifyWebURL(fromURI: ""))
    }

    func testSongLinkNeedsTheSongItselfNotJustTheArtist() {
        let results: [[String: Any]] = [
            ["artistName": "The Artist", "trackName": "Another Song", "trackViewUrl": "https://music.apple.com/a"],
            ["artistName": "The Artist", "trackName": "Song (Remastered)", "trackViewUrl": "https://music.apple.com/b"],
        ]
        // For a cover, the artist is enough; for a link it isn't.
        XCTAssertEqual(
            MusicController.searchResult(in: results, matchingArtist: "The Artist")?["trackViewUrl"] as? String,
            "https://music.apple.com/a"
        )
        XCTAssertEqual(
            MusicController.searchResult(in: results, matchingArtist: "The Artist", title: "Song")?["trackViewUrl"] as? String,
            "https://music.apple.com/b"
        )
        XCTAssertNil(MusicController.searchResult(in: results, matchingArtist: "The Artist", title: "Missing"))
        XCTAssertNil(MusicController.searchResult(in: [], matchingArtist: "", title: "Song"))

        // An exact name beats a version of it, whatever the order.
        let exactLater = results + [["artistName": "The Artist", "trackName": "song", "trackViewUrl": "https://music.apple.com/c"]]
        XCTAssertEqual(
            MusicController.searchResult(in: exactLater, matchingArtist: "The Artist", title: "Song")?["trackViewUrl"] as? String,
            "https://music.apple.com/c"
        )
        XCTAssertTrue(MusicController.isVersion("Song (Live)", of: "song"))
        XCTAssertTrue(MusicController.isVersion("Song - Single", of: "Song"))
        XCTAssertFalse(MusicController.isVersion("Songbird", of: "Song"))
        XCTAssertFalse(MusicController.isVersion("Another Song", of: "Song"))
        XCTAssertFalse(MusicController.isVersion("Song", of: "Song"))
        XCTAssertFalse(MusicController.isVersion("Song", of: ""))

        XCTAssertNotNil(MusicController.appleMusicWebURL(from: "https://music.apple.com/us/album/x/1?i=2&uo=4"))
        XCTAssertNil(MusicController.appleMusicWebURL(from: "http://music.apple.com/us/album/x/1"))
        XCTAssertNil(MusicController.appleMusicWebURL(from: "https://example.com/us/album/x/1"))
        XCTAssertNil(MusicController.appleMusicWebURL(from: "itmss://music.apple.com/us/album/x/1"))
    }

    func testPlaylistParsingRejectsNonHexIDs() {
        let playlists = MusicController.parsePlaylists("0A1B2C\tRoad Trip\nnot-hex\tBad\n3D4E\tTabs\tInside\n")
        XCTAssertEqual(playlists, [
            Playlist(id: "0A1B2C", name: "Road Trip"),
            Playlist(id: "3D4E", name: "Tabs\tInside"),
        ])
    }

    func testPlaybackModesParsing() {
        XCTAssertEqual(MusicController.parsePlaybackModes("true\tone"), PlaybackModes(shuffle: true, repeatMode: .one))
        XCTAssertEqual(MusicController.parsePlaybackModes("false\ttrue"), PlaybackModes(shuffle: false, repeatMode: .all))
        XCTAssertEqual(MusicController.parsePlaybackModes("false\toff"), PlaybackModes(shuffle: false, repeatMode: .off))
        XCTAssertNil(MusicController.parsePlaybackModes("true"))
    }

    func testRatingParsing() {
        XCTAssertEqual(MusicController.parseRating("60\ttrue"), TrackRating(stars: 3, isDisliked: true))
        XCTAssertEqual(MusicController.parseRating("100\tfalse"), TrackRating(stars: 5, isDisliked: false))
        // Older Music has no "disliked"; the stars still come through.
        XCTAssertEqual(MusicController.parseRating("0\t"), TrackRating(stars: 0, isDisliked: nil))
        // Half stars round to the nearest whole one.
        XCTAssertEqual(MusicController.parseRating("50\t")?.stars, 3)
        XCTAssertEqual(MusicController.parseRating("30\t")?.stars, 2)
        XCTAssertNil(MusicController.parseRating(""))
        XCTAssertNil(MusicController.parseRating("many\ttrue"))
        XCTAssertNil(MusicController.parseRating("140\ttrue"))
    }

    func testOutputDeviceParsing() {
        let devices = MusicController.parseOutputDevices("0000000000000000\ttrue\tMac\n000068CAC4EEA768\tfalse\tAirPods\tPro\nnot-hex\tfalse\tX\n")
        XCTAssertEqual(devices, [
            OutputDevice(id: "0000000000000000", name: "Mac", isSelected: true),
            OutputDevice(id: "000068CAC4EEA768", name: "AirPods\tPro", isSelected: false),
        ])
    }

    func testRecentTracksAreNewestFirstUniqueAndCapped() {
        var history: [RecentTrack] = []
        for index in 0..<12 {
            history = RecentTrack.adding(RecentTrack(title: "Song \(index)", artist: "A"), to: history)
        }
        XCTAssertEqual(history.count, RecentTrack.limit)
        XCTAssertEqual(history.first?.title, "Song 11")

        history = RecentTrack.adding(RecentTrack(title: "Song 5", artist: "A"), to: history)
        XCTAssertEqual(history.first?.title, "Song 5")
        XCTAssertEqual(history.filter { $0.title == "Song 5" }.count, 1)
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

    // MARK: - Player arbitration

    func testPausedPlayerDoesNotDisplaceThePlayingOne() {
        // Spotify is playing; Music reports a pause.
        XCTAssertFalse(MusicController.shouldAdopt(
            notificationFrom: .appleMusic, isPlaying: false, activePlayer: .spotify, activeIsPlaying: true
        ))
        // The active player's own pause always counts.
        XCTAssertTrue(MusicController.shouldAdopt(
            notificationFrom: .spotify, isPlaying: false, activePlayer: .spotify, activeIsPlaying: true
        ))
        // A player that starts playing takes over.
        XCTAssertTrue(MusicController.shouldAdopt(
            notificationFrom: .appleMusic, isPlaying: true, activePlayer: .spotify, activeIsPlaying: true
        ))
        // Nothing is playing, so the latest news wins.
        XCTAssertTrue(MusicController.shouldAdopt(
            notificationFrom: .appleMusic, isPlaying: false, activePlayer: .spotify, activeIsPlaying: false
        ))
    }

    func testInitialPlayerPrefersLastUsedThenInstalled() {
        let all = PlayerApp.allCases
        XCTAssertEqual(
            MusicController.initialPlayer(stored: PlayerApp.spotify.rawValue, allowed: all, installed: all),
            .spotify
        )
        // The remembered player is no longer allowed by the settings.
        XCTAssertEqual(
            MusicController.initialPlayer(stored: PlayerApp.spotify.rawValue, allowed: [.appleMusic], installed: all),
            .appleMusic
        )
        // First launch on a Mac with only Spotify installed.
        XCTAssertEqual(MusicController.initialPlayer(stored: nil, allowed: all, installed: [.spotify]), .spotify)
        XCTAssertEqual(MusicController.initialPlayer(stored: "nonsense", allowed: all, installed: []), .appleMusic)
    }

    func testScriptsOnlyReachARunningPlayerAndTimeOut() {
        let script = MusicController.script(for: .spotify, timeout: 7, "playpause")
        XCTAssertTrue(script.contains(#"if application "Spotify" is not running then error number -600"#))
        XCTAssertTrue(script.contains("with timeout of 7 seconds"))
        XCTAssertTrue(script.contains("playpause"))
    }

    func testScriptsCompile() throws {
        // Syntax only: the wrapper must stay valid AppleScript. Plain
        // statements keep this independent of any player's dictionary.
        let source = MusicController.script(for: .appleMusic, "return 1\nreturn 2")
        var error: NSDictionary?
        let compiled = try XCTUnwrap(NSAppleScript(source: source)).compileAndReturnError(&error)
        XCTAssertTrue(compiled, String(describing: error))
    }

    // MARK: - Track identity

    func testTrackIDValidation() {
        XCTAssertTrue(MusicController.isSpotifyURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC"))
        XCTAssertTrue(MusicController.isSpotifyURI("spotify:episode:abc123"))
        XCTAssertFalse(MusicController.isSpotifyURI("spotify:local:Artist:Album:Song:215"))
        XCTAssertFalse(MusicController.isSpotifyURI(#"spotify:track:abc" & (do shell script "x") & ""#))
        XCTAssertFalse(MusicController.isSpotifyURI("spotify:track:"))
        XCTAssertEqual(MusicController.validTrackID("0A1B", for: .appleMusic), "0A1B")
        XCTAssertNil(MusicController.validTrackID("0A1B", for: .spotify))
        XCTAssertNil(MusicController.validTrackID("", for: .appleMusic))
    }

    func testTrackIDFromNotification() {
        XCTAssertEqual(
            MusicController.trackID(fromNotification: ["Track ID": "spotify:track:abc123"], player: .spotify),
            "spotify:track:abc123"
        )
        XCTAssertNil(MusicController.trackID(fromNotification: ["Track ID": "spotify:local:a:b:c:1"], player: .spotify))
        // Music's signed 64-bit number is the hex ID scripts use.
        XCTAssertEqual(
            MusicController.trackID(fromNotification: ["PersistentID": NSNumber(value: Int64(-1))], player: .appleMusic),
            "FFFFFFFFFFFFFFFF"
        )
        XCTAssertEqual(
            MusicController.trackID(fromNotification: ["PersistentID": "255"], player: .appleMusic),
            "00000000000000FF"
        )
        XCTAssertNil(MusicController.trackID(fromNotification: [:], player: .appleMusic))
    }

    func testTrackIdentityTellsAlbumsApartButToleratesAMissingOne() throws {
        func track(_ player: PlayerApp = .appleMusic, title: String = "Song", album: String) -> TrackIdentity? {
            TrackIdentity(player: player, title: title, artist: "A", album: album)
        }
        let single = try XCTUnwrap(track(album: "Single"))
        let live = try XCTUnwrap(track(album: "Live"))
        XCTAssertFalse(single.isSameSong(as: live))
        XCTAssertNotEqual(single.key, live.key)
        XCTAssertFalse(single.isSameSong(as: try XCTUnwrap(track(.spotify, album: "Single"))))
        XCTAssertFalse(single.isSameSong(as: try XCTUnwrap(track(title: "Other", album: "Single"))))

        // A notification without the album is still the same song as the
        // script reading that has it, in either order.
        let unknownAlbum = try XCTUnwrap(track(album: ""))
        XCTAssertTrue(single.isSameSong(as: unknownAlbum))
        XCTAssertTrue(unknownAlbum.isSameSong(as: single))

        XCTAssertNil(track(title: "", album: "B"))
    }

    func testRecentTracksFromOlderVersionsStillLoad() throws {
        let legacy = Data(#"[{"title":"Song","artist":"A"}]"#.utf8)
        let history = try JSONDecoder().decode([RecentTrack].self, from: legacy)
        XCTAssertEqual(history, [RecentTrack(title: "Song", artist: "A")])
        XCTAssertNil(history.first?.trackID)

        // The same song heard again replaces its entry, even with an ID now.
        let replayed = RecentTrack(title: "Song", artist: "A", player: PlayerApp.spotify.rawValue, trackID: "spotify:track:x")
        XCTAssertEqual(RecentTrack.adding(replayed, to: history), [replayed])
    }

    // MARK: - Equalizer

    func testSpectrumPutsATonesEnergyInItsBand() {
        let sampleRate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        func levels(frequency: Double, amplitude: Float = 0.5) -> [CGFloat] {
            let samples = (0..<SpectrumAnalyzer.size).map {
                amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate))
            }
            return WaveformMath.bandLevels(
                magnitudes: analyzer.magnitudes(of: samples),
                sampleRate: sampleRate,
                bandCount: AudioWaveformModel.barCount
            )
        }

        let bass = levels(frequency: 80)
        XCTAssertEqual(bass.count, AudioWaveformModel.barCount)
        XCTAssertEqual(bass.firstIndex(of: bass.max()!), 0)

        let treble = levels(frequency: 9_000)
        XCTAssertEqual(treble.firstIndex(of: treble.max()!), AudioWaveformModel.barCount - 1)
        XCTAssertLessThan(treble[0], 0.2)

        let middle = levels(frequency: 1_000)
        let peak = middle.firstIndex(of: middle.max()!)!
        XCTAssertTrue((2...4).contains(peak), "1 kHz peaked in band \(peak)")
        XCTAssertTrue((bass + treble + middle).allSatisfy { (0...1).contains($0) })
    }

    func testSpectrumOfSilenceIsFlat() {
        let silence = [Float](repeating: 0, count: SpectrumAnalyzer.size)
        let levels = WaveformMath.bandLevels(
            magnitudes: SpectrumAnalyzer().magnitudes(of: silence),
            sampleRate: 44_100,
            bandCount: 7
        )
        XCTAssertEqual(levels, Array(repeating: 0, count: 7))
        XCTAssertEqual(WaveformMath.bandLevels(magnitudes: [], sampleRate: 44_100, bandCount: 7).count, 7)
    }

    func testSpectrumScalesAFullScaleSineToOne() {
        // Exactly on a bin, so no energy leaks to its neighbors.
        let bin = 64
        let samples = (0..<SpectrumAnalyzer.size).map {
            Float(sin(2 * Double.pi * Double(bin) * Double($0) / Double(SpectrumAnalyzer.size)))
        }
        let magnitudes = SpectrumAnalyzer().magnitudes(of: samples)
        XCTAssertEqual(magnitudes.count, SpectrumAnalyzer.size / 2)
        XCTAssertEqual(magnitudes[bin], 1, accuracy: 0.01)
        XCTAssertLessThan(magnitudes[bin + 10], 0.001)
        XCTAssertTrue(SpectrumAnalyzer().magnitudes(of: [1, 2, 3]).isEmpty)
    }

    func testSpectrumOfMusicLikeNoiseUsesTheMiddleOfTheRange() {
        // Noise falling 3 dB per octave is a fair stand-in for mastered
        // music. Its bars should sit mid-height, none pinned or dead.
        var generator = SystemRandomNumberGenerator()
        var rows = [Float](repeating: 0, count: 12)
        var sum: Float = 0
        var samples: [Float] = []
        // Voss-McCartney pink noise.
        for index in 0..<(SpectrumAnalyzer.size * 40) {
            let row = (index + 1).trailingZeroBitCount % rows.count
            sum -= rows[row]
            rows[row] = Float.random(in: -1...1, using: &generator)
            sum += rows[row]
            samples.append(sum)
        }
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        samples = samples.map { $0 / rms * 0.2 } // about -14 dBFS

        let analyzer = SpectrumAnalyzer()
        var totals = [CGFloat](repeating: 0, count: 7)
        let windows = samples.count / SpectrumAnalyzer.size
        for window in 0..<windows {
            let slice = Array(samples[(window * SpectrumAnalyzer.size)..<((window + 1) * SpectrumAnalyzer.size)])
            let levels = WaveformMath.bandLevels(
                magnitudes: analyzer.magnitudes(of: slice), sampleRate: 48_000, bandCount: 7
            )
            for band in 0..<7 { totals[band] += levels[band] }
        }
        let averages = totals.map { $0 / CGFloat(windows) }
        for (band, average) in averages.enumerated() {
            XCTAssertTrue((0.3...0.9).contains(average), "band \(band) averaged \(average)")
        }
    }

    func testSensitivityScalesBarsWithinRange() {
        XCTAssertEqual(WaveformMath.scaled(0.4, by: 1), 0.4, accuracy: 0.0001)
        XCTAssertEqual(WaveformMath.scaled(0.4, by: 2), 0.8, accuracy: 0.0001)
        XCTAssertEqual(WaveformMath.scaled(0.4, by: 0.5), 0.2, accuracy: 0.0001)
        XCTAssertEqual(WaveformMath.scaled(0.8, by: 2), 1)

        let model = AudioWaveformModel()
        model.sensitivity = 2
        let quiet = Array(repeating: CGFloat(0.3), count: AudioWaveformModel.barCount)
        for _ in 0..<40 { model.ingest(quiet) }
        XCTAssertEqual(model.levels[0], 0.6, accuracy: 0.02)
    }

    func testSlidingSampleWindow() {
        var window: [Float] = [1, 2, 3, 4]
        WaveformMath.slide(&window, appending: [5, 6])
        XCTAssertEqual(window, [3, 4, 5, 6])
        WaveformMath.slide(&window, appending: [7, 8, 9, 10, 11])
        XCTAssertEqual(window, [8, 9, 10, 11])
        WaveformMath.slide(&window, appending: [])
        XCTAssertEqual(window, [8, 9, 10, 11])
    }

    func testSimulatedWaveformMovesWithinRange() {
        let first = SimulatedWaveform.levels(at: 10)
        let later = SimulatedWaveform.levels(at: 10.5)
        XCTAssertEqual(first.count, AudioWaveformModel.barCount)
        XCTAssertNotEqual(first, later)
        XCTAssertNotEqual(Set(first).count, 1, "bars should not move in unison")
        for time in stride(from: 0.0, to: 60, by: 0.37) {
            XCTAssertTrue(SimulatedWaveform.levels(at: time).allSatisfy { (0.06...1).contains($0) })
        }
        XCTAssertFalse(EqualizerStyle.simulated.capturesAudio)
        XCTAssertTrue(EqualizerStyle.spectrum.capturesAudio)
    }

    func testBarColorsStayLegibleOnTheMenuBar() {
        func brightness(_ color: NSColor) -> CGFloat {
            (color.usingColorSpace(.sRGB) ?? color).brightnessComponent
        }
        let nearBlack = NSColor(srgbRed: 0.1, green: 0.02, blue: 0.02, alpha: 1)
        XCTAssertGreaterThanOrEqual(brightness(nearBlack.legible(onDarkBackground: true)), 0.59)
        XCTAssertEqual(brightness(nearBlack.legible(onDarkBackground: false)), brightness(nearBlack), accuracy: 0.001)

        let nearWhite = NSColor(srgbRed: 1, green: 0.98, blue: 0.9, alpha: 1)
        XCTAssertLessThanOrEqual(brightness(nearWhite.legible(onDarkBackground: false)), 0.71)
        XCTAssertEqual(brightness(nearWhite.legible(onDarkBackground: true)), brightness(nearWhite), accuracy: 0.001)
    }

    // MARK: - Menu bar and card layout

    func testTitleWidthFitsShortTitles() {
        XCTAssertEqual(MarqueeText.frameWidth(textWidth: 60, maxWidth: 150, fit: true), 60)
        XCTAssertEqual(MarqueeText.frameWidth(textWidth: 400, maxWidth: 150, fit: true), 150)
        XCTAssertEqual(MarqueeText.frameWidth(textWidth: 60, maxWidth: 150, fit: false), 150)
        XCTAssertGreaterThan(MarqueeText.width(of: "A much longer title"), MarqueeText.width(of: "Short"))
        XCTAssertEqual(MarqueeText.width(of: ""), 0)
    }

    func testItemHidesOnlyWhenAskedAndNoPlayerIsOpen() {
        XCTAssertTrue(StatusItemController.shouldShowItem(hideWhenNoPlayer: false, anyPlayerRunning: false))
        XCTAssertTrue(StatusItemController.shouldShowItem(hideWhenNoPlayer: true, anyPlayerRunning: true))
        XCTAssertFalse(StatusItemController.shouldShowItem(hideWhenNoPlayer: true, anyPlayerRunning: false))
    }

    func testTitleFormatFillsPlaceholdersAndDropsDanglingSeparators() {
        func render(_ template: String, artist: String = "Artist", album: String = "Album") -> String {
            TitleFormat.render(template, title: "Song", artist: artist, album: album)
        }
        XCTAssertEqual(render("{title} — {artist}"), "Song — Artist")
        XCTAssertEqual(render("{artist} — {title}"), "Artist — Song")
        XCTAssertEqual(render("{title} — {artist} — {album}"), "Song — Artist — Album")
        XCTAssertEqual(render("♪ {title} by {artist}"), "♪ Song by Artist")

        // A missing value takes its separator with it, wherever it sits.
        XCTAssertEqual(render("{title} — {artist}", artist: ""), "Song")
        XCTAssertEqual(render("{artist} — {title}", artist: ""), "Song")
        XCTAssertEqual(render("{title} — {artist} — {album}", artist: ""), "Song — Album")
        XCTAssertEqual(render("{title} — {artist} — {album}", artist: "", album: ""), "Song")

        // Never blank: with nothing to show, the title stands in.
        XCTAssertEqual(render("{album}", album: ""), "Song")
        XCTAssertEqual(render(""), "Song")
        XCTAssertEqual(render("no placeholders"), "no placeholders")
        // A value is never re-read as a template.
        XCTAssertEqual(TitleFormat.render("{title}", title: "{artist}", artist: "X", album: ""), "{artist}")
        XCTAssertTrue(TitleFormat.presets.contains(TitleFormat.titleAndArtist))
    }

    func testLargerTextIsWider() {
        XCTAssertGreaterThan(
            MarqueeText.width(of: "Some title", fontSize: 14),
            MarqueeText.width(of: "Some title", fontSize: 10)
        )
        XCTAssertEqual(MarqueeText.width(of: "Some title"), MarqueeText.width(of: "Some title", fontSize: 12))
    }

    func testSeekFractionClampsToTheBar() {
        XCTAssertEqual(HoverPopupView.seekFraction(x: 42, width: 168), 0.25, accuracy: 0.0001)
        XCTAssertEqual(HoverPopupView.seekFraction(x: -20, width: 168), 0)
        XCTAssertEqual(HoverPopupView.seekFraction(x: 500, width: 168), 1)
        XCTAssertEqual(HoverPopupView.seekFraction(x: 10, width: 0), 0)
    }

    func testCardSecondLineJoinsArtistAndAlbum() {
        let model = TrackModel()
        model.update(title: "Song", artist: "Artist", album: "Album", isPlaying: true)
        XCTAssertEqual(model.artistAndAlbum, "Artist — Album")
        model.update(title: "Song", artist: "", album: "Album", isPlaying: true)
        XCTAssertEqual(model.artistAndAlbum, "Album")
        model.clear()
        XCTAssertEqual(model.artistAndAlbum, "")
        XCTAssertFalse(model.hasTrack)
    }

    // MARK: - Shortcuts

    func testShortcutNeedsACommandLikeModifier() {
        XCTAssertNil(Shortcut(keyCode: UInt16(kVK_ANSI_M), modifierFlags: [], characters: "m"))
        XCTAssertNil(Shortcut(keyCode: UInt16(kVK_ANSI_M), modifierFlags: [.shift], characters: "M"))
        let shortcut = Shortcut(keyCode: UInt16(kVK_ANSI_M), modifierFlags: [.control, .option, .command], characters: "m")
        XCTAssertEqual(shortcut, HotKeyAction.defaultShortcuts[.toggleCard])
        XCTAssertEqual(shortcut?.displayText, "⌃⌥⌘M")
        XCTAssertEqual(
            Shortcut(keyCode: UInt16(kVK_RightArrow), modifierFlags: [.shift, .command], characters: nil)?.displayText,
            "⇧⌘→"
        )
        // A key with nothing printable to show can't be recorded.
        XCTAssertNil(Shortcut(keyCode: 200, modifierFlags: [.command], characters: nil))
    }

    func testShortcutsSurviveSavingAndStayUnique() throws {
        let saved = try XCTUnwrap(Shortcut.encode(HotKeyAction.defaultShortcuts))
        XCTAssertEqual(Shortcut.decode(saved), HotKeyAction.defaultShortcuts)
        XCTAssertNil(Shortcut.decode(Data("not json".utf8)))

        // Giving Play/Pause the card's combination takes it from the card.
        let card = try XCTUnwrap(HotKeyAction.defaultShortcuts[.toggleCard])
        let moved = Shortcut.assigning(card, to: .playPause, in: HotKeyAction.defaultShortcuts)
        XCTAssertEqual(moved[.playPause], card)
        XCTAssertNil(moved[.toggleCard])
        XCTAssertNotNil(moved[.toggleFavorite])

        XCTAssertNil(Shortcut.assigning(nil, to: .playPause, in: moved)[.playPause])
    }

    func testHotKeyActionsRoundTripThroughTheirIDs() {
        for action in HotKeyAction.allCases {
            XCTAssertEqual(HotKeyAction(id: action.id), action)
        }
        // Only the original three ship with a shortcut; none collide.
        XCTAssertEqual(Set(HotKeyAction.defaultShortcuts.keys), [.toggleCard, .toggleFavorite, .addToPlaylist])
        XCTAssertEqual(Set(HotKeyAction.defaultShortcuts.values.map(\.displayText)).count, 3)
        XCTAssertTrue(HotKeyAction.allCases.allSatisfy { !$0.title.isEmpty })
        XCTAssertNil(HotKeyAction(id: 0))
        XCTAssertNil(HotKeyAction(id: UInt32(HotKeyAction.allCases.count + 1)))
    }

    // MARK: - Listening history

    func testPlayClockCountsOnlyTimeSpentPlaying() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var clock = PlayClock()
        XCTAssertEqual(clock.total(at: start), 0)
        clock.setPlaying(true, at: start)
        XCTAssertEqual(clock.total(at: start.addingTimeInterval(20)), 20)
        clock.setPlaying(false, at: start.addingTimeInterval(20))
        // A long pause adds nothing.
        XCTAssertEqual(clock.total(at: start.addingTimeInterval(500)), 20)
        clock.setPlaying(true, at: start.addingTimeInterval(500))
        // Reporting "playing" again doesn't restart the count.
        clock.setPlaying(true, at: start.addingTimeInterval(505))
        XCTAssertEqual(clock.total(at: start.addingTimeInterval(515)), 35)
    }

    func testListeningHistoryRanksSongsAndArtists() {
        let now = Date()
        func play(_ title: String, _ artist: String, daysAgo: Double) -> Play {
            Play(title: title, artist: artist, album: "", player: "p", date: now.addingTimeInterval(-daysAgo * 86_400))
        }
        let plays = [
            play("A", "X", daysAgo: 40), play("A", "X", daysAgo: 20), play("A", "X", daysAgo: 1),
            play("B", "X", daysAgo: 2), play("B", "X", daysAgo: 3),
            play("C", "Y", daysAgo: 0.5), play("A", "Z", daysAgo: 0.1),
            play("Jingle", "", daysAgo: 0.2),
        ]
        let all = ListeningHistory.topSongs(in: plays, limit: 2)
        XCTAssertEqual(all, [PlayCount(name: "A", detail: "X", count: 3), PlayCount(name: "B", detail: "X", count: 2)])

        // The same title by another artist is another song.
        XCTAssertEqual(ListeningHistory.topSongs(in: plays, limit: 10).count, 5)

        let week = ListeningHistory.plays(plays, since: HistoryPeriod.week.start(from: now))
        XCTAssertEqual(week.count, 6)
        // Within the week B (2) beats A (1); among the singles the most
        // recently played comes first.
        XCTAssertEqual(ListeningHistory.topSongs(in: week, limit: 2).map(\.name), ["B", "A"])

        let artists = ListeningHistory.topArtists(in: plays, limit: 5)
        XCTAssertEqual(artists.first, PlayCount(name: "X", detail: "", count: 5))
        XCTAssertFalse(artists.contains { $0.name.isEmpty })
        XCTAssertNil(HistoryPeriod.all.start(from: now))
        XCTAssertEqual(ListeningHistory.plays(plays, since: nil).count, plays.count)
    }

    func testListeningHistoryPersistsAndClears() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MusicBarTests-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("history.jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let history = ListeningHistory(fileURL: file)
        XCTAssertTrue(history.plays.isEmpty)
        let first = Play(title: "Line\nbreak", artist: "A", album: "B", player: "p", date: Date(timeIntervalSince1970: 1_700_000_000))
        let second = Play(title: "Two", artist: "", album: "", player: "p", date: Date(timeIntervalSince1970: 1_700_000_300))
        history.record(first)
        history.record(second)

        // A new instance, as after a relaunch, reads the same plays back.
        XCTAssertEqual(ListeningHistory(fileURL: file).plays, [first, second])

        // A damaged line is skipped, not fatal.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        XCTAssertEqual(ListeningHistory(fileURL: file).plays.count, 2)

        history.clear()
        XCTAssertTrue(history.plays.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(ListeningHistory(fileURL: file).plays.isEmpty)
    }

    // MARK: - Support

    func testDiagnosticsDescribeTheSetupNotTheListening() {
        let diagnostics = Diagnostics(
            version: "1.2", build: "60", system: "Version 26.0", architecture: "arm64", language: "es",
            installedPlayers: [.appleMusic], runningPlayers: [], activePlayer: .appleMusic,
            hasTrack: true, isPlaying: false, playersWithoutPermission: [.spotify],
            equalizerShown: true, equalizerStyle: .spectrum, captureFailed: true,
            playerMode: .automatic, unavailableShortcuts: [.toggleCard], notificationsEnabled: false
        )
        let report = diagnostics.report
        XCTAssertTrue(report.contains("MusicBar 1.2 (60)"))
        XCTAssertTrue(report.contains("Players installed: Music"))
        XCTAssertTrue(report.contains("Players running: none"))
        XCTAssertTrue(report.contains("Automation refused for: Spotify"))
        XCTAssertTrue(report.contains("Equalizer: spectrum, audio capture failed"))
        XCTAssertTrue(report.contains("Track on display: yes, paused"))
        XCTAssertTrue(report.contains("toggleCard"))
        XCTAssertFalse(Diagnostics.architecture.isEmpty)
        // The type has nowhere to put a title or artist.
        let fields = Mirror(reflecting: diagnostics).children.compactMap(\.label)
        XCTAssertFalse(fields.contains { ["title", "artist", "album", "recent"].contains($0) })
    }

    func testResetRestoresEverySetting() {
        let settings = AppSettings.shared
        defer { settings.resetToDefaults() }
        settings.resetToDefaults()
        func snapshot() -> [String: String] {
            Dictionary(uniqueKeysWithValues: AppSettings.persistedKeys.map {
                ($0, String(describing: UserDefaults.standard.object(forKey: $0)))
            })
        }
        let defaults = snapshot()
        XCTAssertTrue(AppSettings.persistedKeys.contains("titleFormat"))
        XCTAssertFalse(AppSettings.persistedKeys.contains("recordingShortcut"))
        // Every setting ends up saved again, so none was skipped by the reset.
        for key in AppSettings.persistedKeys {
            XCTAssertNotNil(UserDefaults.standard.object(forKey: key), "\(key) is missing from resetToDefaults()")
        }

        settings.playerMode = .spotify
        settings.showArtwork = false
        settings.titleFormat = "{album}"
        settings.textWidth = 240
        settings.equalizerStyle = .simulated
        settings.equalizerSensitivity = 1.7
        settings.doubleClickOpensPlayer = true
        settings.shortcuts = [:]
        XCTAssertNotEqual(snapshot(), defaults)

        settings.resetToDefaults()
        XCTAssertEqual(snapshot(), defaults)
        XCTAssertEqual(settings.playerMode, .automatic)
        XCTAssertEqual(settings.titleFormat, TitleFormat.titleAndArtist)
        XCTAssertEqual(settings.shortcuts, HotKeyAction.defaultShortcuts)
    }

    // MARK: - Sleep timer

    private func makeDefaults() throws -> UserDefaults {
        let name = "MusicBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testSleepTimerAtEndOfTrackFiresOnTheNextSong() throws {
        var fired = 0
        let timer = SleepTimer(defaults: try makeDefaults(), onFire: { fired += 1 }, onChange: {})
        XCTAssertFalse(timer.isActive)
        timer.trackDidChange()
        XCTAssertEqual(fired, 0, "an idle timer ignores track changes")

        timer.set(.endOfTrack)
        XCTAssertTrue(timer.isActive)
        timer.trackDidChange()
        XCTAssertEqual(fired, 1)
        XCTAssertFalse(timer.isActive)
        timer.trackDidChange()
        XCTAssertEqual(fired, 1, "it fires once")
    }

    func testSleepTimerCountdownSurvivesARelaunch() throws {
        let defaults = try makeDefaults()
        let timer = SleepTimer(defaults: defaults, onFire: {}, onChange: {})
        timer.set(.minutes(30))
        let end = try XCTUnwrap(timer.end)
        XCTAssertEqual(end.timeIntervalSinceNow, 30 * 60, accuracy: 5)

        // A new instance, as after quitting and reopening.
        let relaunched = SleepTimer(defaults: defaults, onFire: {}, onChange: {})
        XCTAssertEqual(relaunched.mode, .minutes(30))
        XCTAssertEqual(relaunched.end, end)

        relaunched.set(.off)
        XCTAssertFalse(SleepTimer(defaults: defaults, onFire: {}, onChange: {}).isActive)
    }

    func testSleepTimerFadeLowersVolumeTowardZero() {
        XCTAssertEqual(SleepTimer.fadeFraction(remaining: SleepTimer.fadeDuration), 1)
        XCTAssertEqual(SleepTimer.fadeFraction(remaining: SleepTimer.fadeDuration / 2), 0.5, accuracy: 0.0001)
        XCTAssertEqual(SleepTimer.fadeFraction(remaining: 0), 0)
        XCTAssertEqual(SleepTimer.fadeFraction(remaining: 600), 1)
        XCTAssertEqual(SleepTimer.fadeFraction(remaining: -5), 0)

        XCTAssertEqual(SleepTimer.fadedVolume(base: 80, fraction: 0.5), 40)
        XCTAssertEqual(SleepTimer.fadedVolume(base: 80, fraction: 0), 0)
        XCTAssertEqual(SleepTimer.fadedVolume(base: 80, fraction: 1), 80)
        // Never louder than where it started.
        XCTAssertEqual(SleepTimer.fadedVolume(base: 80, fraction: 1.5), 80)
    }

    func testCustomSleepTimerMinutes() {
        XCTAssertEqual(SleepTimer.customMinutes(from: "45"), 45)
        XCTAssertEqual(SleepTimer.customMinutes(from: " 5 "), 5)
        XCTAssertEqual(SleepTimer.customMinutes(from: "720"), 720)
        XCTAssertNil(SleepTimer.customMinutes(from: "0"))
        XCTAssertNil(SleepTimer.customMinutes(from: "721"))
        XCTAssertNil(SleepTimer.customMinutes(from: "-10"))
        XCTAssertNil(SleepTimer.customMinutes(from: "soon"))
        XCTAssertNil(SleepTimer.customMinutes(from: ""))
    }

    func testSleepTimerIgnoresADeadlineThatPassed() {
        let now = Date()
        XCTAssertNil(SleepTimer.pendingEnd(now.addingTimeInterval(-1), now: now))
        XCTAssertNil(SleepTimer.pendingEnd(nil, now: now))
        XCTAssertEqual(SleepTimer.pendingEnd(now.addingTimeInterval(60), now: now), now.addingTimeInterval(60))
    }

    // MARK: - Network

    func testOnlyKnownImageHostsAreDownloaded() throws {
        func trusted(_ string: String) throws -> Bool {
            ArtworkDownloader.isTrustedArtworkURL(try XCTUnwrap(URL(string: string)))
        }
        XCTAssertTrue(try trusted("https://i.scdn.co/image/ab67616d0000b273"))
        XCTAssertTrue(try trusted("https://is1-ssl.mzstatic.com/image/thumb/a/600x600bb.jpg"))
        XCTAssertFalse(try trusted("http://i.scdn.co/image/ab67616d0000b273"))
        XCTAssertFalse(try trusted("https://example.com/cover.jpg"))
        XCTAssertFalse(try trusted("https://evilscdn.co/cover.jpg"))
        XCTAssertFalse(try trusted("https://scdn.co.example.com/cover.jpg"))
        XCTAssertFalse(try trusted("file:///etc/passwd"))
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("v1.2", than: "1.1"))
        XCTAssertTrue(UpdateChecker.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1.1", than: "1.1"))
        XCTAssertFalse(UpdateChecker.isNewer("v1.1", than: "1.1"))
        XCTAssertFalse(UpdateChecker.isNewer("1.1", than: "1.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.1"))
        XCTAssertFalse(UpdateChecker.isNewer("garbage", than: "1.1"))
        XCTAssertEqual(UpdateChecker.normalized("v2.0"), "2.0")
    }
}
