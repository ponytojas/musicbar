import AppKit
import AudioToolbox
import AVFoundation
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
}

/// Captures only Apple Music or Spotify's output with a Core Audio process
/// tap. The HAL callback does a small RMS reduction and publishes at 15 Hz;
/// no PCM audio is retained or written anywhere.
final class AudioWaveformCapture: @unchecked Sendable {
    private let setupQueue = DispatchQueue(label: "MusicBar.waveform.setup", qos: .utility)
    private let audioQueue = DispatchQueue(label: "MusicBar.waveform.audio", qos: .userInteractive)
    private let onLevels: @Sendable ([CGFloat]) -> Void
    private let onStopped: @Sendable () -> Void

    // setupQueue-only state.
    private var capturedPlayer: PlayerApp?
    private var processTapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var deviceProcID: AudioDeviceIOProcID?

    // audioQueue-only.
    private var lastPublishNanoseconds: UInt64 = 0

    init(
        onLevels: @escaping @Sendable ([CGFloat]) -> Void,
        onStopped: @escaping @Sendable () -> Void
    ) {
        self.onLevels = onLevels
        self.onStopped = onStopped

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

    func capture(_ player: PlayerApp?) {
        setupQueue.async { [weak self] in
            guard let self, player != self.capturedPlayer else { return }
            self.switchOnSetupQueue(to: player)
        }
    }

    private func switchOnSetupQueue(to player: PlayerApp?) {
        stopOnSetupQueue()
        guard let player else { return }
        do {
            try startOnSetupQueue(player)
            capturedPlayer = player
        } catch {
            Logger.musicBar.error("Waveform capture unavailable: \(error.localizedDescription, privacy: .public)")
            stopOnSetupQueue()
        }
    }

    private func startOnSetupQueue(_ player: PlayerApp) throws {
        guard #available(macOS 14.2, *) else {
            throw CaptureError.unsupportedSystem
        }

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

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateID,
            audioQueue
        ) { [weak self] _, inputData, _, _, _ in
            self?.consume(inputData, format: format)
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
            if #available(macOS 14.2, *) {
                _ = AudioHardwareDestroyProcessTap(processTapID)
            }
        }
        deviceProcID = nil
        aggregateDeviceID = kAudioObjectUnknown
        processTapID = kAudioObjectUnknown
        capturedPlayer = nil
        onStopped()
    }

    private func consume(
        _ inputData: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        let interval: UInt64 = 66_666_667 // 15 UI updates per second.
        guard now &- lastPublishNanoseconds >= interval else { return }
        lastPublishNanoseconds = now

        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
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

    @available(macOS 14.2, *)
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

    @available(macOS 14.2, *)
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
        case unsupportedSystem
        case playerHasNoAudioProcess
        case noOutputDevice
        case unsupportedAudioFormat
        case coreAudio(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .unsupportedSystem: "Real waveform capture requires macOS 14.2 or later."
            case .playerHasNoAudioProcess: "The player has no active Core Audio process."
            case .noOutputDevice: "No system output device is available."
            case .unsupportedAudioFormat: "The player's audio format isn't supported."
            case let .coreAudio(operation, status): "Could not \(operation) (Core Audio \(status))."
            }
        }
    }
}
