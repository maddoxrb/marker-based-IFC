import Foundation
import AVFoundation
import Speech
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

struct SpeakerVerificationChallenge: Equatable {
    let markerName: String
    let pincode: String
}

struct SpeakerMatch {
    let profile: SpeakerProfile
    let confidence: Double
}

struct SpeakerScore: Identifiable, Equatable {
    let profileID: String
    let profileName: String
    let accessLevel: AccessLevel
    let score: Double

    var id: String { profileID }

    var debugSummary: String {
        "\(profileName) (\(accessLevel.displayName)): \(score.formatted(.number.precision(.fractionLength(3))))"
    }
}

struct SpeakerEvaluation {
    let bestMatch: SpeakerMatch?
    let scores: [SpeakerScore]
}

struct RecordedAuthenticationSample {
    let sampleURL: URL
    let transcript: String
    let speakerEvaluationResult: Result<SpeakerEvaluation, Error>?
}

protocol VoiceSampleRecording {
    func recordSample(duration: TimeInterval, destinationURL: URL?) async throws -> URL
    func recordAuthenticationSample(
        duration: TimeInterval,
        speakerEvaluationSession: (any LiveSpeakerEvaluating)?
    ) async throws -> RecordedAuthenticationSample
}

extension VoiceSampleRecording {
    func recordSample(duration: TimeInterval) async throws -> URL {
        try await recordSample(duration: duration, destinationURL: nil)
    }
}

protocol LiveSpeakerEvaluating: AnyObject {
    var requiredSampleRate: Int { get }
    var requiredFrameLength: Int { get }

    func process(frame: [Int16]) throws
    func finish() throws -> SpeakerEvaluation
}

protocol SpeakerAuthenticating {
    func makeEvaluationSession(against profiles: [SpeakerProfile]) async throws -> any LiveSpeakerEvaluating
}

enum SpeakerAuthenticationError: LocalizedError {
    case microphonePermissionDenied
    case speechRecognitionPermissionDenied
    case speechRecognitionUnavailable
    case speechRecognitionFailed
    case recordingFailed
    case picovoiceAccessKeyMissing
    case eagleSDKNotInstalled
    case missingReferenceClips
    case noSpeakerProfilesConfigured
    case enrollmentFailed(profileName: String, detail: String?)
    case noSpeakerMatch
    case challengeCodeMismatch(transcript: String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is required for speaker authentication."
        case .speechRecognitionPermissionDenied:
            return "Speech recognition permission is required for pincode verification."
        case .speechRecognitionUnavailable:
            return "Speech recognition is currently unavailable."
        case .speechRecognitionFailed:
            return "Unable to transcribe the spoken pincode."
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
        case .enrollmentFailed(let profileName, let detail):
            if let detail, !detail.isEmpty {
                return "Unable to enroll speaker profile for \(profileName). \(detail)"
            }
            return "Unable to enroll speaker profile for \(profileName). Record 2-3 clear clips for that speaker and try again."
        case .noSpeakerMatch:
            return "Speaker authentication failed. Try speaking again."
        case .challengeCodeMismatch(let transcript):
            let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if transcript.isEmpty {
                return "Pincode verification failed. Try the new code."
            }
            return "Pincode verification failed. Heard \"\(transcript)\"."
        }
    }
}

enum SpokenPincodeMatcher {
    private static let digitTokens: [String: String] = [
        "zero": "0",
        "oh": "0",
        "o": "0",
        "one": "1",
        "won": "1",
        "two": "2",
        "too": "2",
        "to": "2",
        "three": "3",
        "four": "4",
        "for": "4",
        "five": "5",
        "six": "6",
        "seven": "7",
        "eight": "8",
        "ate": "8",
        "nine": "9"
    ]

    static func transcript(_ transcript: String, contains code: String) -> Bool {
        guard !code.isEmpty else { return false }

        let lowercaseTranscript = transcript.lowercased()
        let directDigits = lowercaseTranscript.filter { $0.isNumber }
        if directDigits.contains(code) {
            return true
        }

        let spokenDigits = lowercaseTranscript
            .split { !$0.isLetter && !$0.isNumber }
            .compactMap { mapTokenToDigits($0) }
            .joined()

        return spokenDigits.contains(code)
    }

    private static func mapTokenToDigits(_ token: Substring) -> String? {
        let token = String(token)
        if token.allSatisfy({ $0.isNumber }) {
            return token
        }

        return digitTokens[token]
    }
}

private actor SpeechTranscriptCollector {
    private var transcript = ""
    private var isFinished = false
    private var shouldThrowFailure = false

    func update(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            transcript = result.bestTranscription.formattedString
            if result.isFinal {
                isFinished = true
            }
        }

        if error != nil {
            shouldThrowFailure = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            isFinished = true
        }
    }

    func awaitBestTranscript(timeoutNanoseconds: UInt64) async throws -> String {
        let pollInterval: UInt64 = 100_000_000
        var elapsed: UInt64 = 0

        while true {
            try Task.checkCancellation()

            if isFinished {
                if shouldThrowFailure {
                    throw SpeakerAuthenticationError.speechRecognitionFailed
                }
                return transcript
            }

            if elapsed >= timeoutNanoseconds {
                return transcript
            }

            try await Task.sleep(nanoseconds: pollInterval)
            elapsed += pollInterval
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
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]

    func recordSample(duration: TimeInterval, destinationURL: URL?) async throws -> URL {
        guard await requestRecordPermission() else {
            throw SpeakerAuthenticationError.microphonePermissionDenied
        }

        try configureRecordingSession()
        defer { deactivateRecordingSession() }

        let outputURL = destinationURL ?? Self.temporaryClipURL()
        if let destinationURL {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        let recorder = try AVAudioRecorder(url: outputURL, settings: Self.settings)
        recorder.prepareToRecord()
        guard recorder.record() else { throw SpeakerAuthenticationError.recordingFailed }

        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        recorder.stop()

        let recordedFile = try AVAudioFile(forReading: outputURL)
        guard recordedFile.length > 0 else {
            throw SpeakerAuthenticationError.recordingFailed
        }

        return outputURL
    }

    func recordAuthenticationSample(
        duration: TimeInterval,
        speakerEvaluationSession: (any LiveSpeakerEvaluating)?
    ) async throws -> RecordedAuthenticationSample {
        guard await requestRecordPermission() else {
            throw SpeakerAuthenticationError.microphonePermissionDenied
        }
        guard await requestSpeechRecognitionPermission() else {
            throw SpeakerAuthenticationError.speechRecognitionPermissionDenied
        }

        guard let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer(),
              speechRecognizer.isAvailable else {
            throw SpeakerAuthenticationError.speechRecognitionUnavailable
        }

        try configureRecordingSession()
        defer { deactivateRecordingSession() }

        let outputURL = Self.temporaryClipURL(pathExtension: "caf")
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let audioFile = try AVAudioFile(forWriting: outputURL, settings: inputFormat.settings)
        let liveFrameExtractor = try speakerEvaluationSession.map {
            try LivePCMFrameExtractor(
                inputFormat: inputFormat,
                targetSampleRate: $0.requiredSampleRate,
                targetFrameLength: $0.requiredFrameLength
            )
        }
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }

        let transcriptCollector = SpeechTranscriptCollector()
        var recognitionTask: SFSpeechRecognitionTask?
        var didInstallTap = false
        var evaluationProcessingError: Error?

        defer {
            if didInstallTap {
                inputNode.removeTap(onBus: 0)
            }
            audioEngine.stop()
            recognitionRequest.endAudio()
            recognitionTask?.cancel()
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, _ in
            recognitionRequest.append(buffer)
            try? audioFile.write(from: buffer)

            guard evaluationProcessingError == nil,
                  let liveFrameExtractor,
                  let speakerEvaluationSession else {
                return
            }

            do {
                let frames = try liveFrameExtractor.append(buffer)
                for frame in frames {
                    try speakerEvaluationSession.process(frame: frame)
                }
            } catch {
                evaluationProcessingError = error
            }
        }
        didInstallTap = true

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { result, error in
            Task {
                await transcriptCollector.update(result: result, error: error)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        try Task.checkCancellation()

        inputNode.removeTap(onBus: 0)
        didInstallTap = false
        audioEngine.stop()
        recognitionRequest.endAudio()

        let transcript = try await transcriptCollector.awaitBestTranscript(timeoutNanoseconds: 2_000_000_000)
        let speakerEvaluationResult: Result<SpeakerEvaluation, Error>?

        if let evaluationProcessingError {
            speakerEvaluationResult = .failure(evaluationProcessingError)
        } else if let liveFrameExtractor, let speakerEvaluationSession {
            do {
                let finalFrames = try liveFrameExtractor.finish()
                for frame in finalFrames {
                    try speakerEvaluationSession.process(frame: frame)
                }
                speakerEvaluationResult = .success(try speakerEvaluationSession.finish())
            } catch {
                speakerEvaluationResult = .failure(error)
            }
        } else {
            speakerEvaluationResult = nil
        }

        return RecordedAuthenticationSample(
            sampleURL: outputURL,
            transcript: transcript,
            speakerEvaluationResult: speakerEvaluationResult
        )
    }

    private static func temporaryClipURL(pathExtension: String = "caf") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(pathExtension)
    }

    private func configureRecordingSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try? session.setPreferredSampleRate(16_000)
        try? session.setPreferredInputNumberOfChannels(1)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func deactivateRecordingSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestSpeechRecognitionPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

enum SpeakerClipStore {
    private static let sessionDirectoryName = "SpeakerClips-\(UUID().uuidString)"

    static func clipDirectoryURL() throws -> URL {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(sessionDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func clipURL(for clipName: String) -> URL? {
        guard let url = try? clipDirectoryURL().appendingPathComponent(clipName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func nextClipURL(for speakerID: String, pathExtension: String = "caf") throws -> URL {
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

final class LivePCMFrameExtractor {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let targetFrameLength: Int
    private var pendingSamples: [Int16] = []

    init(inputFormat: AVAudioFormat, targetSampleRate: Int, targetFrameLength: Int) throws {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(targetSampleRate),
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw SpeakerAuthenticationError.recordingFailed
        }

        self.converter = converter
        self.outputFormat = outputFormat
        self.targetFrameLength = targetFrameLength
    }

    func append(_ buffer: AVAudioPCMBuffer) throws -> [[Int16]] {
        let estimatedCapacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * (outputFormat.sampleRate / buffer.format.sampleRate)).rounded(.up)
            + Double(targetFrameLength)
        )
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: estimatedCapacity) else {
            throw SpeakerAuthenticationError.recordingFailed
        }

        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = AVAudioConverterInputStatus.noDataNow
                return nil
            }

            suppliedInput = true
            outStatus.pointee = AVAudioConverterInputStatus.haveData
            return buffer
        }

        guard conversionError == nil,
              status == .haveData || status == .inputRanDry || status == .endOfStream,
              let channelData = outputBuffer.int16ChannelData else {
            throw SpeakerAuthenticationError.recordingFailed
        }

        let convertedSamples = Array(
            UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength))
        )
        if !convertedSamples.isEmpty {
            pendingSamples.append(contentsOf: convertedSamples)
        }

        return drainFrames(padRemainder: false)
    }

    func finish() throws -> [[Int16]] {
        drainFrames(padRemainder: true)
    }

    private func drainFrames(padRemainder: Bool) -> [[Int16]] {
        var frames: [[Int16]] = []

        while pendingSamples.count >= targetFrameLength {
            let frame = Array(pendingSamples.prefix(targetFrameLength))
            frames.append(frame)
            pendingSamples.removeFirst(targetFrameLength)
        }

        if padRemainder, !pendingSamples.isEmpty {
            var finalFrame = pendingSamples
            finalFrame.append(contentsOf: repeatElement(0, count: targetFrameLength - finalFrame.count))
            frames.append(finalFrame)
            pendingSamples.removeAll()
        }

        return frames
    }
}

#if canImport(Eagle) || canImport(pveagle)
private struct EagleScoreAccumulator {
    private static let minimumVoicedFrameLevelDBFS = -50.0

    private let speakerCount: Int
    private var voicedScoresBySpeaker: [[Float]]

    private(set) var voicedFrameCount = 0

    init(speakerCount: Int) {
        self.speakerCount = speakerCount
        self.voicedScoresBySpeaker = Array(repeating: [], count: speakerCount)
    }

    mutating func append(scores: [Float], frame: [Int16]) {
        guard scores.count == speakerCount,
              Self.isVoiced(frame) else {
            return
        }

        for index in scores.indices {
            voicedScoresBySpeaker[index].append(scores[index])
        }
        voicedFrameCount += 1
    }

    func summarizedScores(fallbackTotals: [Float], processedFrames: Int) -> [Float] {
        guard voicedFrameCount > 0 else {
            guard processedFrames > 0 else {
                return Array(repeating: .zero, count: speakerCount)
            }

            return fallbackTotals.map { $0 / Float(processedFrames) }
        }

        return voicedScoresBySpeaker.map(Self.upperWindowMean)
    }

    private static func upperWindowMean(_ scores: [Float]) -> Float {
        guard !scores.isEmpty else { return .zero }

        let sortedScores = scores.sorted()
        let retainedCount = max(3, Int(ceil(Double(sortedScores.count) * 0.35)))
        let retainedScores = sortedScores.suffix(retainedCount)
        let total = retainedScores.reduce(Float.zero, +)

        return total / Float(retainedScores.count)
    }

    private static func isVoiced(_ frame: [Int16]) -> Bool {
        guard !frame.isEmpty else { return false }

        let meanSquare = frame.reduce(0.0) { partialResult, sample in
            let normalizedSample = Double(sample) / Double(Int16.max)
            return partialResult + (normalizedSample * normalizedSample)
        } / Double(frame.count)

        guard meanSquare > 0 else { return false }

        let rms = sqrt(meanSquare)
        let levelDBFS = 20.0 * log10(max(rms, 1e-7))
        return levelDBFS >= minimumVoicedFrameLevelDBFS
    }
}

final class PicovoiceEagleLiveSession: LiveSpeakerEvaluating {
    let requiredSampleRate: Int = Eagle.sampleRate
    let requiredFrameLength: Int = Eagle.frameLength

    private let recognitionThreshold: Float
    private let profiles: [SpeakerProfile]
    private let eagle: Eagle
    private var totals: [Float]
    private var scoreAccumulator: EagleScoreAccumulator
    private var processedFrames = 0

    init(
        accessKey: String,
        profiles: [SpeakerProfile],
        eagleProfiles: [EagleProfile],
        recognitionThreshold: Float
    ) throws {
        self.recognitionThreshold = recognitionThreshold
        self.profiles = profiles
        self.eagle = try Eagle(accessKey: accessKey, speakerProfiles: eagleProfiles)
        self.totals = Array(repeating: .zero, count: profiles.count)
        self.scoreAccumulator = EagleScoreAccumulator(speakerCount: profiles.count)
        try eagle.reset()
    }

    deinit {
        eagle.delete()
    }

    func process(frame: [Int16]) throws {
        let scores = try eagle.process(pcm: frame)
        for index in scores.indices {
            totals[index] += scores[index]
        }
        scoreAccumulator.append(scores: scores, frame: frame)
        processedFrames += 1
    }

    func finish() throws -> SpeakerEvaluation {
        let summarizedScores = scoreAccumulator.summarizedScores(
            fallbackTotals: totals,
            processedFrames: processedFrames
        )

        let scoredProfiles = zip(profiles, summarizedScores)
            .map { profile, score in
                SpeakerScore(
                    profileID: profile.id,
                    profileName: profile.displayName,
                    accessLevel: profile.accessLevel,
                    score: Double(score)
                )
            }
            .sorted { $0.score > $1.score }

        let bestMatch: SpeakerMatch?
        if let highestScoringProfile = scoredProfiles.first,
           highestScoringProfile.score >= Double(recognitionThreshold),
           let profile = profiles.first(where: { $0.id == highestScoringProfile.profileID }) {
            bestMatch = SpeakerMatch(profile: profile, confidence: highestScoringProfile.score)
        } else {
            bestMatch = nil
        }

        return SpeakerEvaluation(bestMatch: bestMatch, scores: scoredProfiles)
    }
}

actor PicovoiceEagleSpeakerAuthenticator: SpeakerAuthenticating {
    private let recognitionThreshold: Float = 0.3
    private var cachedProfiles: [SpeakerProfile] = []
    private var cachedEagleProfiles: [EagleProfile] = []

    func makeEvaluationSession(against profiles: [SpeakerProfile]) async throws -> any LiveSpeakerEvaluating {
        guard !profiles.isEmpty else { throw SpeakerAuthenticationError.noSpeakerProfilesConfigured }
        guard let accessKey = PicovoiceConfiguration.eagleAccessKey else {
            throw SpeakerAuthenticationError.picovoiceAccessKeyMissing
        }

        let eagleProfiles = try eagleProfiles(for: profiles, accessKey: accessKey)
        return try PicovoiceEagleLiveSession(
            accessKey: accessKey,
            profiles: profiles,
            eagleProfiles: eagleProfiles,
            recognitionThreshold: recognitionThreshold
        )
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

        let minEnrollSamples = try profiler.minEnrollSamples()
        var completion: Float = 0
        var lastFeedbackDescription: String?

        for clipURL in clips where completion < 100 {
            let pcm = try PCMConverter.int16MonoPcm(from: clipURL, targetSampleRate: EagleProfiler.sampleRate)
            guard pcm.count >= minEnrollSamples else {
                lastFeedbackDescription = "A recorded clip did not contain enough audio samples for Eagle enrollment."
                continue
            }

            for start in stride(from: 0, through: pcm.count - minEnrollSamples, by: minEnrollSamples) where completion < 100 {
                let end = start + minEnrollSamples
                let chunk = Array(pcm[start..<end])
                let (percentage, feedback) = try profiler.enroll(pcm: chunk)
                completion = max(completion, percentage)
                lastFeedbackDescription = "Eagle feedback: \(String(describing: feedback))."
            }
        }

        guard completion >= 100 else {
            let detailSuffix = lastFeedbackDescription.map { " Last Eagle feedback: \($0)" } ?? ""
            let detail = "Enrollment reached only \(Int(completion))%.\(detailSuffix) Record 2-3 clear clips, speak continuously, and avoid background noise."
            throw SpeakerAuthenticationError.enrollmentFailed(profileName: profile.displayName, detail: detail)
        }

        return try profiler.export()
    }
}
#else
actor PicovoiceEagleSpeakerAuthenticator: SpeakerAuthenticating {
    func makeEvaluationSession(against profiles: [SpeakerProfile]) async throws -> any LiveSpeakerEvaluating {
        throw SpeakerAuthenticationError.eagleSDKNotInstalled
    }
}
#endif
