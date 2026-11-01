import Foundation
import CoreAudio
import AudioToolbox

enum TapError: Error, CustomStringConvertible {
    case os(String, OSStatus)
    var description: String {
        switch self {
        case let .os(what, status): "\(what) failed (\(status))"
        }
    }
}

/// Captures everything the Mac is playing using a Core Audio process tap (macOS 14.2+).
/// This uses the "System Audio Recording" permission — never the microphone.
final class SystemAudioTap: @unchecked Sendable {
    private let analyzer: BeatAnalyzer
    private let queue = DispatchQueue(label: "glowrim.audio", qos: .userInteractive)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var running = false

    /// Called (on an arbitrary queue) when the default output device changes, e.g. headphones plugged in.
    var onDeviceChange: (() -> Void)?

    init(analyzer: BeatAnalyzer) {
        self.analyzer = analyzer
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue) { [weak self] _, _ in
            self?.onDeviceChange?()
        }
    }

    func start() throws {
        guard !running else { return }

        // 1. A global stereo tap of all processes.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { cleanup(); throw TapError.os("Creating audio tap", err) }

        // 2. A private aggregate device that contains the tap, so we can read from it.
        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Glowrim Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard err == noErr else { cleanup(); throw TapError.os("Creating aggregate device", err) }

        // 3. Read the tap's sample rate.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd) == noErr, asbd.mSampleRate > 0 {
            analyzer.setSampleRate(asbd.mSampleRate)
        }

        // 4. Stream buffers into the analyzer.
        let analyzer = self.analyzer
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inInputData, _, _, _ in
            analyzer.process(inInputData)
        }
        guard err == noErr, let procID else { cleanup(); throw TapError.os("Creating IO proc", err) }

        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { cleanup(); throw TapError.os("Starting audio", err) }

        running = true
    }

    func stop() {
        cleanup()
        analyzer.reset()
    }

    private func cleanup() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        running = false
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        guard err == noErr else { throw TapError.os("Reading default output device", err) }

        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        err = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid)
        guard err == noErr, let value = uid?.takeRetainedValue() else {
            throw TapError.os("Reading output device UID", err)
        }
        return value as String
    }
}
