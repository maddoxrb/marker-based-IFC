import Foundation
import AVFoundation
import UIKit
#if canImport(Eagle)
import Eagle
#endif
#if canImport(pveagle)
import pveagle
#endif

enum AuthenticationMode: String, CaseIterable, Identifiable {
    case manual
    case speaker

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

struct SpeakerProfile: Identifiable, Equatable, Hashable, Codable {
    let id: String
    var displayName: String
    var accessLevel: AccessLevel
    var referenceClipNames: [String]
}

struct AuthenticatedSpeaker: Equatable {
    let profile: SpeakerProfile
    let confidence: Double?
}

struct SpeakerMatch {
    let profile: SpeakerProfile
    let confidence: Double
}

protocol VoiceSampleRecording {
    func recordSample(duration: TimeInterval, destinationURL: URL?) async throws -> URL
}

extension VoiceSampleRecording {
    func recordSample(duration: TimeInterval) async throws -> URL {
        try await recordSample(duration: duration, destinationURL: nil)
    }
}

protocol SpeakerAuthenticating {
    func matchSpeaker(sampleURL: URL, against profiles: [SpeakerProfile]) async throws -> SpeakerMatch
}

enum SpeakerAuthenticationError: LocalizedError {
    case microphonePermissionDenied
    case recordingFailed
    case picovoiceAccessKeyMissing
    case eagleSDKNotInstalled
    case missingReferenceClips
    case noSpeakerProfilesConfigured
    case enrollmentFailed(profileName: String)
    case noSpeakerMatch

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is required for speaker authentication."
        case .recordingFailed:
            return "Unable to capture a voice sample."
        case .picovoiceAccessKeyMissing:
            return "Set PICOVOICE_ACCESS_KEY before using speaker authentication."
        case .eagleSDKNotInstalled:
            return "Picovoice Eagle is not installed yet. Add `Eagle-iOS` or the Eagle SPM package."
        case .missingReferenceClips:
            return "No bundled speaker enrollment clips were found."
        case .noSpeakerProfilesConfigured:
            return "No speaker profiles are configured. Add one in the speaker admin screen."
        case .enrollmentFailed(let profileName):
            return "Unable to enroll speaker profile for \(profileName)."
        case .noSpeakerMatch:
            return "Speaker authentication failed. Try speaking again."
        }
    }
}

// Can provide API key if attempting to compile
enum PicovoiceConfiguration {
    private static let accessKeyInfoKey = "PICOVOICE_ACCESS_KEY"
    private static let configurationPlistName = "Picovoice"

    static var eagleAccessKey: String? {
        [
            bundledAccessKey(),
            Bundle.main.object(forInfoDictionaryKey: accessKeyInfoKey) as? String,
            Bundle.main.infoDictionary?[accessKeyInfoKey] as? String,
            ProcessInfo.processInfo.environment[accessKeyInfoKey],
            UserDefaults.standard.string(forKey: accessKeyInfoKey)
        ]
        .compactMap(normalizedAccessKey)
        .first
    }

    private static func bundledAccessKey() -> String? {
        guard let configURL = Bundle.main.url(forResource: configurationPlistName, withExtension: "plist"),
              let configData = try? Data(contentsOf: configURL),
              let propertyList = try? PropertyListSerialization.propertyList(from: configData, options: [], format: nil),
              let dictionary = propertyList as? [String: Any] else {
            return nil
        }

        return normalizedAccessKey(dictionary[accessKeyInfoKey] as? String)
    }

    private static func normalizedAccessKey(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }

        let trimmed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        return trimmed.isEmpty || trimmed == "CHANGE_ME" ? nil : trimmed
    }
}

// Credit PicoVoice for setup code
final class VoiceSampleRecorder: VoiceSampleRecording {
    private static let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]

    func recordSample(duration: TimeInterval, destinationURL: URL?) async throws -> URL {
        guard await requestRecordPermission() else {
            throw SpeakerAuthenticationError.microphonePermissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .duckOthers, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        defer { try? session.setActive(false, options: .notifyOthersOnDeactivation) }

        let outputURL = destinationURL ?? Self.temporaryClipURL()
        if let destinationURL {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        let recorder = try AVAudioRecorder(url: outputURL, settings: Self.settings)
        guard recorder.record() else { throw SpeakerAuthenticationError.recordingFailed }

        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        recorder.stop()
        return outputURL
    }

    private static func temporaryClipURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
    }

    private func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

enum SpeakerClipStore {
    private static let directoryName = "SpeakerClips"

    static func clipDirectoryURL() throws -> URL {
        let url = try FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func clipURL(for clipName: String) -> URL? {
        guard let url = try? clipDirectoryURL().appendingPathComponent(clipName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func nextClipURL(for speakerID: String, pathExtension: String = "m4a") throws -> URL {
        try clipDirectoryURL().appendingPathComponent("\(speakerID.replacingOccurrences(of: " ", with: "-"))-\(UUID().uuidString).\(pathExtension)")
    }

    static func deleteClip(named clipName: String) {
        guard let url = clipURL(for: clipName) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

enum AudioClipResolver {
    static func url(for clipName: String, in bundle: Bundle = .main) throws -> URL {
        let fileName = clipName as NSString
        let baseName = fileName.deletingPathExtension
        let pathExtension = fileName.pathExtension

        if let fileURL = SpeakerClipStore.clipURL(for: clipName)
            ?? bundle.url(forResource: baseName, withExtension: pathExtension.isEmpty ? nil : pathExtension) {
            return fileURL
        }

        if let dataAsset = NSDataAsset(name: clipName) ?? NSDataAsset(name: baseName) {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(pathExtension.isEmpty ? "m4a" : pathExtension)
            try dataAsset.data.write(to: tempURL, options: .atomic)
            return tempURL
        }

        throw SpeakerAuthenticationError.missingReferenceClips
    }
}

enum PCMConverter {
    static func int16MonoPcm(from url: URL, targetSampleRate: Int) throws -> [Int16] {
        let audioFile = try AVAudioFile(forReading: url)
        let inputFormat = audioFile.processingFormat
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(audioFile.length)) else {
            throw SpeakerAuthenticationError.recordingFailed
        }

        try audioFile.read(into: inputBuffer)

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(targetSampleRate),
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw SpeakerAuthenticationError.recordingFailed
        }

        let estimatedCapacity = AVAudioFrameCount((Double(inputBuffer.frameLength) * (outputFormat.sampleRate / inputFormat.sampleRate)).rounded(.up) + 512)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: estimatedCapacity) else {
            throw SpeakerAuthenticationError.recordingFailed
        }

        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .endOfStream
                return nil
            }

            suppliedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil,
              status == .haveData || status == .endOfStream,
              let channelData = outputBuffer.int16ChannelData else {
            throw SpeakerAuthenticationError.recordingFailed
        }

        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}

#if canImport(Eagle) || canImport(pveagle)
actor PicovoiceEagleSpeakerAuthenticator: SpeakerAuthenticating {
    private let recognitionThreshold: Float = 0.55
    private var cachedProfiles: [SpeakerProfile] = []
    private var cachedEagleProfiles: [EagleProfile] = []

    func matchSpeaker(sampleURL: URL, against profiles: [SpeakerProfile]) async throws -> SpeakerMatch {
        guard !profiles.isEmpty else { throw SpeakerAuthenticationError.noSpeakerProfilesConfigured }
        guard let accessKey = PicovoiceConfiguration.eagleAccessKey else {
            throw SpeakerAuthenticationError.picovoiceAccessKeyMissing
        }

        let eagleProfiles = try eagleProfiles(for: profiles, accessKey: accessKey)
        let pcm = try PCMConverter.int16MonoPcm(from: sampleURL, targetSampleRate: Eagle.sampleRate)
        let scores = try averageScores(for: pcm, accessKey: accessKey, profiles: eagleProfiles)

        guard let bestMatch = scores.enumerated().max(by: { $0.element < $1.element }),
              bestMatch.element >= recognitionThreshold else {
            throw SpeakerAuthenticationError.noSpeakerMatch
        }

        return SpeakerMatch(profile: profiles[bestMatch.offset], confidence: Double(bestMatch.element))
    }

    private func eagleProfiles(for profiles: [SpeakerProfile], accessKey: String) throws -> [EagleProfile] {
        if cachedProfiles == profiles, cachedEagleProfiles.count == profiles.count {
            return cachedEagleProfiles
        }

        let eagleProfiles = try profiles.map { try enroll($0, accessKey: accessKey) }
        cachedProfiles = profiles
        cachedEagleProfiles = eagleProfiles
        return eagleProfiles
    }

    private func enroll(_ profile: SpeakerProfile, accessKey: String) throws -> EagleProfile {
        let profiler = try EagleProfiler(accessKey: accessKey)
        defer { profiler.delete() }

        try profiler.reset()

        let clips = try profile.referenceClipNames.map { try AudioClipResolver.url(for: $0) }
        guard !clips.isEmpty else { throw SpeakerAuthenticationError.missingReferenceClips }

        var completion: Float = 0
        for clipURL in clips where completion < 100 {
            let pcm = try PCMConverter.int16MonoPcm(from: clipURL, targetSampleRate: EagleProfiler.sampleRate)
            if !pcm.isEmpty {
                completion = try profiler.enroll(pcm: pcm).0
            }
        }

        guard completion >= 100 else {
            throw SpeakerAuthenticationError.enrollmentFailed(profileName: profile.displayName)
        }

        return try profiler.export()
    }

    private func averageScores(for pcm: [Int16], accessKey: String, profiles: [EagleProfile]) throws -> [Float] {
        guard !pcm.isEmpty else { throw SpeakerAuthenticationError.noSpeakerMatch }

        let eagle = try Eagle(accessKey: accessKey, speakerProfiles: profiles)
        defer { eagle.delete() }

        try eagle.reset()

        let frameLength = Eagle.frameLength
        var totals = Array(repeating: Float.zero, count: profiles.count)
        var processedFrames = 0

        for start in stride(from: 0, to: pcm.count, by: frameLength) {
            let end = min(start + frameLength, pcm.count)
            var frame = Array(pcm[start..<end])
            if frame.count < frameLength {
                frame.append(contentsOf: repeatElement(0, count: frameLength - frame.count))
            }

            let scores = try eagle.process(pcm: frame)
            for index in scores.indices {
                totals[index] += scores[index]
            }
            processedFrames += 1
        }

        return totals.map { $0 / Float(processedFrames) }
    }
}
#else
actor PicovoiceEagleSpeakerAuthenticator: SpeakerAuthenticating {
    func matchSpeaker(sampleURL: URL, against profiles: [SpeakerProfile]) async throws -> SpeakerMatch {
        throw SpeakerAuthenticationError.eagleSDKNotInstalled
    }
}
#endif
