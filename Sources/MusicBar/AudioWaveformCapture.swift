import Accelerate
import AppKit
import AudioToolbox
import CoreAudio
import os

private let waveformBarCount = 7

@MainActor
protocol AudioWaveformConsumer: AnyObject {
    func displayWaveformLevels(_ levels: [CGFloat])
}

/// The small main-actor bridge consumed by the menu-bar waveform. It talks
/// directly to the AppKit drawing view so audio updates don't invalidate the
/// surrounding SwiftUI title, artwork, or status-item layout.
@MainActor
final class AudioWaveformModel {
    static let barCount = waveformBarCount

    private(set) var levels = Array(repeating: CGFloat(0.08), count: barCount)
    private weak var consumer: (any AudioWaveformConsumer)?

    func connect(_ consumer: any AudioWaveformConsumer) {
        self.consumer = consumer
        consumer.displayWaveformLevels(levels)
    }

    func ingest(_ incoming: [CGFloat]) {
        guard incoming.count == Self.barCount else { return }
        var nextLevels = levels
        var changed = false
        for index in levels.indices {
            let target = incoming[index]
            let response: CGFloat = target > levels[index] ? 0.72 : 0.28
            let next = levels[index] + (target - levels[index]) * response
            if abs(next - levels[index]) > 0.006 {
                nextLevels[index] = next
                changed = true
            }
        }
        if changed {
            levels = nextLevels
            consumer?.displayWaveformLevels(nextLevels)
        }
    }

    func reset() {
        let resting = Array(repeating: CGFloat(0.08), count: Self.barCount)
        if levels != resting {
            levels = resting
            consumer?.displayWaveformLevels(resting)
        }
    }
}

enum WaveformMath {
    /// Maps RMS amplitude to the visible range. The logarithmic mapping keeps
    /// quiet passages alive without letting mastered tracks pin every bar.
    static func normalizedLevel(rms: Float) -> CGFloat {
        guard rms.isFinite, rms > 0.000_01 else { return 0 }
        let decibels = 20 * log10(Double(rms))
        return CGFloat(min(1, max(0, (decibels + 52) / 52)))
    }

    /// Mastered music has little short-term RMS variation. Lowering the visual
    /// center and expanding deviations keeps the real signal readable at the
    /// menu bar's tiny height without inventing synthetic movement.
    static func displayLevels(from levels: [CGFloat]) -> [CGFloat] {
        guard !levels.isEmpty else { return [] }
        let average = levels.reduce(0, +) / CGFloat(levels.count)
        guard average > 0.01 else { return Array(repeating: 0, count: levels.count) }
        let visualCenter = min(0.72, average * 0.72)
        return levels.map { level in
            min(1, max(0.04, visualCenter + (level - average) * 3.2))
        }
    }

    /// Groups FFT magnitudes into `bandCount` bars, bass first. Bands are
    /// spaced evenly in pitch from 50 Hz to 14 kHz, the way an equalizer
    /// lays them out. `magnitudes` are the first half of the spectrum,
    /// scaled so a full-scale sine reads 1.
    static func bandLevels(magnitudes: [Float], sampleRate: Double, bandCount: Int) -> [CGFloat] {
        let silent = Array(repeating: CGFloat(0), count: max(0, bandCount))
        let lowest = 50.0
        let highest = min(14_000, sampleRate / 2)
        guard magnitudes.count > 1, bandCount > 0, highest > lowest else { return silent }
        let binWidth = sampleRate / Double(magnitudes.count * 2)
        let ratio = highest / lowest
        return (0..<bandCount).map { band in
            let from = lowest * pow(ratio, Double(band) / Double(bandCount))
            let to = lowest * pow(ratio, Double(band + 1) / Double(bandCount))
            // Bin 0 is DC, which carries no sound.
            let firstBin = min(magnitudes.count - 1, max(1, Int(from / binWidth)))
            let lastBin = min(magnitudes.count - 1, max(firstBin, Int(to / binWidth) - 1))
            var energy: Float = 0
            for bin in firstBin...lastBin {
                energy += magnitudes[bin] * magnitudes[bin]
            }
            let rms = (energy / Float(lastBin - firstBin + 1)).squareRoot()
            // Music carries about 3 dB less per octave going up; without
            // this tilt the bass bars would tower over a flat treble.
            let octavesUp = log2((from * to).squareRoot() / lowest)
            let tilt = Float(pow(10, 3 * octavesUp / 20))
            return normalizedLevel(rms: rms * tilt)
        }
    }

    /// Slides `window` forward to end with `samples`, keeping its length.
    static func slide(_ window: inout [Float], appending samples: [Float]) {
        guard !window.isEmpty, !samples.isEmpty else { return }
        if samples.count >= window.count {
            window = Array(samples.suffix(window.count))
        } else {
            window.removeFirst(samples.count)
            window.append(contentsOf: samples)
        }
    }
}

/// Movement for the "simulated" equalizer: a few slow sine waves per bar,
/// out of step with each other. It reads no audio at all.
enum SimulatedWaveform {
    static func levels(at time: TimeInterval, count: Int = waveformBarCount) -> [CGFloat] {
        (0..<count).map { index -> CGFloat in
            let bar = Double(index)
            let slow: Double = sin(time * (0.9 + bar * 0.13) + bar * 2.1)
            let medium: Double = sin(time * (2.1 + bar * 0.37) + bar * 1.3)
            let fast: Double = sin(time * (5.3 + bar * 0.91) + bar * 0.7)
            let level: Double = 0.45 + 0.12 * slow + 0.22 * medium + 0.16 * fast
            return CGFloat(min(1, max(0.06, level)))
        }
    }
}

/// Windowed FFT of the last `size` samples. Not thread-safe; the capture
/// uses it from its audio queue only.
final class SpectrumAnalyzer {
    /// 2048 samples resolve about 23 Hz at 48 kHz: enough to tell the two
    /// lowest bars apart. Half that leaves the bass bar a single bin.
    static let size = 2048

    private let setup: vDSP_DFT_Setup?
    private let window: [Float]
    private let zeros = [Float](repeating: 0, count: size)
    private var windowed = [Float](repeating: 0, count: size)
    private var real = [Float](repeating: 0, count: size)
    private var imaginary = [Float](repeating: 0, count: size)

    init() {
        setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.size), .FORWARD)
        // Hann: peak 1, so a sine's two halves add up to size / 4 in its bin.
        window = (0..<Self.size).map { 0.5 * (1 - cos(2 * Float.pi * Float($0) / Float(Self.size))) }
    }

    deinit {
        if let setup { vDSP_DFT_DestroySetup(setup) }
    }

    /// First half of the spectrum, scaled so a full-scale sine reads 1.
    func magnitudes(of samples: [Float]) -> [Float] {
        guard let setup, samples.count == Self.size else { return [] }
        for index in 0..<Self.size {
            windowed[index] = samples[index] * window[index]
        }
        vDSP_DFT_Execute(setup, windowed, zeros, &real, &imaginary)
        let scale = Float(Self.size) / 4
        return (0..<Self.size / 2).map { bin in
            (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).squareRoot() / scale
        }
    }
}

/// Captures only Apple Music or Spotify's output with a Core Audio process
/// tap. The HAL callback reduces each buffer to seven levels and publishes
/// at 15 Hz; no PCM audio is written anywhere, and at most the last 2048
/// samples (about 43 ms, for the frequency analysis) stay in memory.
final class AudioWaveformCapture: @unchecked Sendable {
    private let setupQueue = DispatchQueue(label: "MusicBar.waveform.setup", qos: .utility)
    private let audioQueue = DispatchQueue(label: "MusicBar.waveform.audio", qos: .userInteractive)
    private let onLevels: @Sendable ([CGFloat]) -> Void
    private let onStopped: @Sendable () -> Void
    /// true once a capture starts, false when one couldn't.
    private let onAvailability: @Sendable (Bool) -> Void

    // setupQueue-only state.
    private var capturedPlayer: PlayerApp?
    private var capturesSpectrum = true
    private var processTapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var deviceProcID: AudioDeviceIOProcID?

    // audioQueue-only.
    private var lastPublishNanoseconds: UInt64 = 0
    private var recentSamples = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    private let analyzer = SpectrumAnalyzer()

    init(
        onLevels: @escaping @Sendable ([CGFloat]) -> Void,
        onStopped: @escaping @Sendable () -> Void,
        onAvailability: @escaping @Sendable (Bool) -> Void
    ) {
        self.onLevels = onLevels
        self.onStopped = onStopped
        self.onAvailability = onAvailability

        // The aggregate device is bound to the output device present at start;
        // rebuild it when the user switches output (AirPods, unplugging, …).
        // App-lifetime object, so the listener is never removed.
        var address = Self.defaultOutputDeviceAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            setupQueue
        ) { [weak self] _, _ in
            guard let self, let player = self.capturedPlayer else { return }
            self.switchOnSetupQueue(to: player)
        }
    }

    /// Starts capturing `player`, or stops with nil. `spectrum` picks
    /// frequency bands over plain loudness. A capture that failed is tried
    /// again on the next call.
    func capture(_ player: PlayerApp?, spectrum: Bool = true) {
        setupQueue.async { [weak self] in
            guard let self else { return }
            let sameStyle = player == nil || spectrum == self.capturesSpectrum
            guard player != self.capturedPlayer || !sameStyle else { return }
            self.capturesSpectrum = spectrum
            self.switchOnSetupQueue(to: player)
        }
    }

    private func switchOnSetupQueue(to player: PlayerApp?) {
        stopOnSetupQueue()
        guard let player else { return }
        do {
            try startOnSetupQueue(player)
            capturedPlayer = player
            onAvailability(true)
        } catch {
            Logger.musicBar.error("Waveform capture unavailable: \(error.localizedDescription, privacy: .public)")
            stopOnSetupQueue()
            onAvailability(false)
        }
    }

    private func startOnSetupQueue(_ player: PlayerApp) throws {
        let processIDs = try Self.audioProcessObjectIDs(for: player)
        guard !processIDs.isEmpty else { throw CaptureError.playerHasNoAudioProcess }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processIDs)
        tapDescription.uuid = UUID()
        tapDescription.name = "MusicBar \(player.scriptName) waveform"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try Self.check(AudioHardwareCreateProcessTap(tapDescription, &tapID), operation: "create process tap")
        processTapID = tapID

        let outputDevice = try Self.defaultOutputDevice()
        let outputUID = try Self.deviceUID(outputDevice)
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MusicBar Waveform",
            kAudioAggregateDeviceUIDKey: "com.ponytojas.musicbar.waveform.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
            ]],
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        try Self.check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
            operation: "create aggregate device"
        )
        aggregateDeviceID = aggregateID

        let format = try Self.tapFormat(tapID)
        guard format.mFormatID == kAudioFormatLinearPCM else {
            throw CaptureError.unsupportedAudioFormat
        }

        let spectrum = capturesSpectrum
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateID,
            audioQueue
        ) { [weak self] _, inputData, _, _, _ in
            self?.consume(inputData, format: format, spectrum: spectrum)
        }
        try Self.check(status, operation: "create audio callback")
        deviceProcID = procID
        try Self.check(AudioDeviceStart(aggregateID, procID), operation: "start audio capture")
    }

    private func stopOnSetupQueue() {
        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if let deviceProcID {
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if processTapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(processTapID)
        }
        deviceProcID = nil
        aggregateDeviceID = kAudioObjectUnknown
        processTapID = kAudioObjectUnknown
        capturedPlayer = nil
        onStopped()
    }

    private func consume(
        _ inputData: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription,
        spectrum: Bool
    ) {
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))

        // The FFT looks at more than one callback's worth of audio, so
        // every buffer is folded in, not just the ones that get published.
        if spectrum, let buffer = buffers.first {
            let mono = Self.monoSamples(buffer, isFloat: isFloat, isSignedInteger: isSignedInteger, format: format)
            WaveformMath.slide(&recentSamples, appending: mono)
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let interval: UInt64 = 66_666_667 // 15 UI updates per second.
        guard now &- lastPublishNanoseconds >= interval else { return }
        lastPublishNanoseconds = now

        if spectrum {
            onLevels(WaveformMath.bandLevels(
                magnitudes: analyzer.magnitudes(of: recentSamples),
                sampleRate: format.mSampleRate,
                bandCount: waveformBarCount
            ))
            return
        }

        var sums = Array(repeating: Double(0), count: waveformBarCount)
        var counts = Array(repeating: 0, count: waveformBarCount)

        for buffer in buffers {
            guard let rawData = buffer.mData else { continue }
            let channelCount = max(1, Int(buffer.mNumberChannels))
            if isFloat, format.mBitsPerChannel == 32 {
                let samples = rawData.assumingMemoryBound(to: Float.self)
                Self.accumulate(
                    sampleCount: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size,
                    channelCount: channelCount,
                    sums: &sums,
                    counts: &counts
                ) { Double(samples[$0]) }
            } else if isSignedInteger, format.mBitsPerChannel == 16 {
                let samples = rawData.assumingMemoryBound(to: Int16.self)
                Self.accumulate(
                    sampleCount: Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size,
                    channelCount: channelCount,
                    sums: &sums,
                    counts: &counts
                ) { Double(samples[$0]) / Double(Int16.max) }
            }
        }

        let measuredLevels = sums.indices.map { index -> CGFloat in
            guard counts[index] > 0 else { return 0 }
            return WaveformMath.normalizedLevel(rms: Float(sqrt(sums[index] / Double(counts[index]))))
        }
        onLevels(WaveformMath.displayLevels(from: measuredLevels))
    }

    /// Averages a buffer's channels into mono; empty for formats the tap
    /// isn't expected to deliver.
    private static func monoSamples(
        _ buffer: AudioBuffer,
        isFloat: Bool,
        isSignedInteger: Bool,
        format: AudioStreamBasicDescription
    ) -> [Float] {
        guard let rawData = buffer.mData else { return [] }
        let channelCount = max(1, Int(buffer.mNumberChannels))
        let sample: (Int) -> Float
        let sampleCount: Int
        if isFloat, format.mBitsPerChannel == 32 {
            let samples = rawData.assumingMemoryBound(to: Float.self)
            sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            sample = { samples[$0] }
        } else if isSignedInteger, format.mBitsPerChannel == 16 {
            let samples = rawData.assumingMemoryBound(to: Int16.self)
            sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
            sample = { Float(samples[$0]) / Float(Int16.max) }
        } else {
            return []
        }
        return (0..<sampleCount / channelCount).map { frame in
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += sample(frame * channelCount + channel)
            }
            return sum / Float(channelCount)
        }
    }

    /// Sums squared samples into one bucket per bar; `sample` reads and
    /// scales the interleaved sample at an index.
    private static func accumulate(
        sampleCount: Int,
        channelCount: Int,
        sums: inout [Double],
        counts: inout [Int],
        sample: (Int) -> Double
    ) {
        let frameCount = sampleCount / channelCount
        guard frameCount > 0 else { return }
        for frame in 0..<frameCount {
            let bucket = min(sums.count - 1, frame * sums.count / frameCount)
            for channel in 0..<channelCount {
                let value = sample(frame * channelCount + channel)
                sums[bucket] += value * value
                counts[bucket] += 1
            }
        }
    }

    private static func audioProcessObjectIDs(for player: PlayerApp) throws -> [AudioObjectID] {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: player.rawValue)
        return try applications.compactMap { application in
            var pid = application.processIdentifier
            var objectID = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = withUnsafePointer(to: &pid) { qualifier in
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    UInt32(MemoryLayout<pid_t>.size),
                    qualifier,
                    &size,
                    &objectID
                )
            }
            try check(status, operation: "find player audio process")
            return objectID == kAudioObjectUnknown ? nil : objectID
        }
    }

    private static let defaultOutputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func defaultOutputDevice() throws -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = defaultOutputDeviceAddress
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                &device
            ),
            operation: "read default output device"
        )
        guard device != kAudioObjectUnknown else { throw CaptureError.noOutputDevice }
        return device
    }

    private static func deviceUID(_ device: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        try withUnsafeMutablePointer(to: &uid) { pointer in
            try check(
                AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer),
                operation: "read output device UID"
            )
        }
        return uid as String
    }

    private static func tapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format),
            operation: "read tap format"
        )
        return format
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else { throw CaptureError.coreAudio(operation, status) }
    }

    private enum CaptureError: LocalizedError {
        case playerHasNoAudioProcess
        case noOutputDevice
        case unsupportedAudioFormat
        case coreAudio(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .playerHasNoAudioProcess: "The player has no active Core Audio process."
            case .noOutputDevice: "No system output device is available."
            case .unsupportedAudioFormat: "The player's audio format isn't supported."
            case let .coreAudio(operation, status): "Could not \(operation) (Core Audio \(status))."
            }
        }
    }
}
