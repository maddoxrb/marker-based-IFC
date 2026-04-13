import Foundation
import SwiftUI
import Combine
import ARKit

typealias ARObjectID = String

// Manages all app state, including marker policies, speaker profiles, 
// and authentication status. Shared as an environment object across pages
// For actual UI see /pages

final class AppModel: ObservableObject {
    private static let manualModeMessage = "Manual role selection controls visibility."
    private static let noSpeakerProfilesMessage = "No enrolled speakers configured. Add one in Manage Speakers."
    private static let readyForSpeakerMessage = "Scan a marker, then speak to authenticate."
    static let voiceRecordingDuration: TimeInterval = 10 // 10 seems to be the best balance for identification
    static let authenticationRecordingDuration: TimeInterval = 6

    // see assets/ARresources for the defaut marker images
    private static let defaultMarkerPolicies: [String: MarkerPolicy] = [
        "MarkerA": MarkerPolicy(minimumRole: .public, objectID: PresetObject.cubeGreen.rawValue),
        "MarkerB": MarkerPolicy(minimumRole: .employee, objectID: PresetObject.coneBlue.rawValue),
        "MarkerC": MarkerPolicy(minimumRole: .admin, objectID: PresetObject.spherePurple.rawValue)
    ]

    // toggle between manual role selection for testing and actual speaker authentication
    @Published var authenticationMode: AuthenticationMode = .manual {
        didSet {
            resetSpeakerAuthentication()
            speakerAuthenticationStatus = authenticationMode == .manual ? Self.manualModeMessage : speakerModeStatus
        }
    }

    @Published var currentAccessLevel: AccessLevel = .public
    @Published var runtimeReferenceImages: Set<ARReferenceImage> = []
    @Published var markerPolicies: [String: MarkerPolicy] = AppModel.defaultMarkerPolicies
    @Published var speakerProfiles: [SpeakerProfile]
    @Published private(set) var authenticatedSpeaker: AuthenticatedSpeaker?
    @Published private(set) var speakerAuthenticationStatus = AppModel.manualModeMessage
    @Published private(set) var speakerVerificationChallenge: SpeakerVerificationChallenge?
    @Published private(set) var lastAuthenticationTranscript: String?
    @Published private(set) var lastAuthenticationFailureCause: AuthenticationFailureCause?
    @Published private(set) var lastSpeakerScores: [SpeakerScore] = []

    private let speakerAuthenticator: any SpeakerAuthenticating
    private let voiceSampleRecorder: any VoiceSampleRecording
    private var authenticationTask: Task<Void, Never>?
    private var lastObservedMarker: String?
    private var lastAttemptedMarker: String?

    init(
        speakerAuthenticator: (any SpeakerAuthenticating)? = nil,
        voiceSampleRecorder: (any VoiceSampleRecording)? = nil
    ) {
        speakerProfiles = []
        self.speakerAuthenticator = speakerAuthenticator ?? PicovoiceEagleSpeakerAuthenticator()
        self.voiceSampleRecorder = voiceSampleRecorder ?? VoiceSampleRecorder()
    }

    // Info for the control panel UI
    var effectiveAccessLevel: AccessLevel {
        authenticationMode == .manual ? currentAccessLevel : authenticatedSpeaker?.profile.accessLevel ?? .public
    }
    var activeIdentitySummary: String {
        switch authenticationMode {
        case .manual:
            return "Manual role: \(currentAccessLevel.displayName)"
        case .speaker:
            return authenticatedSpeaker.map { "\($0.profile.displayName) • \($0.profile.accessLevel.displayName)" } ?? "Unauthenticated"
        }
    }

    var isSpeakerAuthenticationInProgress: Bool {
        authenticationTask != nil
    }

    var authenticationDisplaySignature: String {
        let challenge = speakerVerificationChallenge.map { "\($0.markerName):\($0.pincode)" } ?? "none"
        let speakerID = authenticatedSpeaker?.profile.id ?? "none"
        let failureCause = lastAuthenticationFailureCause?.displayName ?? "none"
        let authenticationState = authenticationTask == nil ? "idle" : "active"
        return "\(authenticationMode.rawValue)|\(speakerID)|\(challenge)|\(failureCause)|\(authenticationState)"
    }

    // logic for add marker page, see page/AddMarkerSheet.swift
    func addMarkerImage(name: String, cgImage: CGImage, physicalWidthMeters: CGFloat) {
        let image = ARReferenceImage(cgImage, orientation: .up, physicalWidth: physicalWidthMeters)
        image.name = name
        runtimeReferenceImages.insert(image)

        if markerPolicies[name] == nil {
            markerPolicies[name] = MarkerPolicy(minimumRole: .public, objectID: PresetObject.cubeGreen.rawValue)
        }
    }

    // logic for policy manager page, see page/PolicyEditorView.swift
    func setPolicy(for markerName: String, minimumRole: AccessLevel, objectID: ARObjectID) {
        markerPolicies[markerName] = MarkerPolicy(minimumRole: minimumRole, objectID: objectID)
    }

    func availableMarkerNames() -> [String] {
        Array(Set(markerPolicies.keys).union(runtimeReferenceImages.compactMap { $0.name })).sorted()
    }

    func handleMarkerScan(_ markerName: String) {
        lastObservedMarker = markerName
        let requiredLevel = markerPolicy(for: markerName).minimumRole

        guard requiredLevel != .public else { return }

        guard authenticationMode == .speaker,
              authenticatedSpeaker == nil,
              authenticationTask == nil,
              lastAttemptedMarker != markerName else { return }
        startSpeakerAuthentication(for: markerName)
    }

    // TODO: May want to change this logic, currenty must rescan marker after failure
    func retrySpeakerAuthentication() {
        guard let markerName = speakerVerificationChallenge?.markerName ?? lastObservedMarker else {
            speakerAuthenticationStatus = "Scan a marker before retrying voice authentication."
            return
        }
        startSpeakerAuthentication(for: markerName, force: true)
    }

    func clearSpeakerAuthentication() {
        resetSpeakerAuthentication()
        speakerAuthenticationStatus = speakerProfiles.isEmpty
            ? Self.noSpeakerProfilesMessage
            : "Authentication cleared. Scan a marker, then speak to authenticate."
    }

    func verificationLabelText(for markerName: String) -> String? {
        guard case .pincode(let pincode) = markerBillboard(for: markerName) else { return nil }
        return pincode
    }

    func shouldDisplayObject(for markerName: String) -> Bool {
        let requiredLevel = markerPolicy(for: markerName).minimumRole

        switch authenticationMode {
        case .manual:
            return currentAccessLevel.dominates(requiredLevel)
        case .speaker:
            if requiredLevel == .public {
                return true
            }

            guard let authenticatedSpeaker else { return false }
            return authenticatedSpeaker.profile.accessLevel.dominates(requiredLevel)
        }
    }

    func markerBillboard(for markerName: String) -> MarkerBillboard? {
        guard !shouldDisplayObject(for: markerName) else { return nil }

        switch authenticationMode {
        case .manual:
            return .restricted
        case .speaker:
            let requiredLevel = markerPolicy(for: markerName).minimumRole
            guard requiredLevel != .public else { return nil }

            if authenticatedSpeaker != nil {
                return .restricted
            }

            guard let challenge = speakerVerificationChallenge,
                  challenge.markerName == markerName else {
                return nil
            }

            if lastAuthenticationFailureCause != nil {
                return .restricted
            }

            return .pincode(challenge.pincode)
        }
    }

    func addSpeakerProfile(name: String, accessLevel: AccessLevel) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        speakerProfiles.append(SpeakerProfile(id: UUID().uuidString, displayName: name, accessLevel: accessLevel, referenceClipNames: []))
        refreshSpeakerStatusIfNeeded()
    }

    func updateSpeakerProfile(id: String, name: String, accessLevel: AccessLevel) {
        guard let index = speakerProfileIndex(for: id) else { return }

        speakerProfiles[index].displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        speakerProfiles[index].accessLevel = accessLevel
    }

    func deleteSpeakerProfile(id: String) {
        guard let index = speakerProfileIndex(for: id) else { return }

        let deletedProfile = speakerProfiles.remove(at: index)
        deletedProfile.referenceClipNames.forEach(SpeakerClipStore.deleteClip(named:))
        if authenticatedSpeaker?.profile.id == deletedProfile.id {
            authenticatedSpeaker = nil
        }

        refreshSpeakerStatusIfNeeded()
    }

    func deleteSpeakerClip(_ clipName: String, from profileID: String) {
        guard let index = speakerProfileIndex(for: profileID) else { return }

        speakerProfiles[index].referenceClipNames.removeAll { $0 == clipName }
        SpeakerClipStore.deleteClip(named: clipName)
    }

    func recordSpeakerClip(for profileID: String, duration: TimeInterval = AppModel.voiceRecordingDuration) async throws {
        guard let index = speakerProfileIndex(for: profileID) else { return }

        let recordedURL = try await voiceSampleRecorder.recordSample(
            duration: duration,
            destinationURL: try SpeakerClipStore.nextClipURL(for: profileID)
        )
        let clipName = recordedURL.lastPathComponent

        if !speakerProfiles[index].referenceClipNames.contains(clipName) {
            speakerProfiles[index].referenceClipNames.append(clipName)
        }

        refreshSpeakerStatusIfNeeded()
    }

    private var speakerModeStatus: String {
        speakerProfiles.isEmpty ? Self.noSpeakerProfilesMessage : Self.readyForSpeakerMessage
    }

    private func startSpeakerAuthentication(for markerName: String, force: Bool = false) {
        guard authenticationMode == .speaker else { return }
        guard markerPolicy(for: markerName).minimumRole != .public else { return }
        guard !speakerProfiles.isEmpty else {
            speakerAuthenticationStatus = Self.noSpeakerProfilesMessage
            return
        }
        guard force || (authenticatedSpeaker == nil && authenticationTask == nil && lastAttemptedMarker != markerName) else {
            return
        }

        authenticationTask?.cancel()
        authenticationTask = nil
        if force {
            authenticatedSpeaker = nil
        }

        let challenge = ensureSpeakerVerificationChallenge(for: markerName)
        lastAttemptedMarker = markerName
        lastAuthenticationTranscript = nil
        lastAuthenticationFailureCause = nil
        lastSpeakerScores = []
        speakerAuthenticationStatus = "Speak naturally for \(markerName) and include pin \(challenge.pincode)."

        authenticationTask = Task { [weak self] in
            guard let self else { return }

            do {
                let speakerEvaluationSession: (any LiveSpeakerEvaluating)?
                let speakerEvaluationSetupError: Error?

                do {
                    speakerEvaluationSession = try await self.speakerAuthenticator.makeEvaluationSession(against: self.speakerProfiles)
                    speakerEvaluationSetupError = nil
                } catch {
                    speakerEvaluationSession = nil
                    speakerEvaluationSetupError = error
                }

                let authenticationSample = try await self.voiceSampleRecorder.recordAuthenticationSample(
                    duration: Self.authenticationRecordingDuration,
                    speakerEvaluationSession: speakerEvaluationSession
                )
                try Task.checkCancellation()

                await MainActor.run {
                    self.lastAuthenticationTranscript = authenticationSample.transcript
                    self.speakerAuthenticationStatus = "Matching voice sample and pincode for \(markerName)..."
                }

                let codeMatched = SpokenPincodeMatcher.transcript(authenticationSample.transcript, contains: challenge.pincode)
                let speakerEvaluationResult: Result<SpeakerEvaluation, Error>
                if let speakerEvaluationResultFromSample = authenticationSample.speakerEvaluationResult {
                    speakerEvaluationResult = speakerEvaluationResultFromSample
                } else if let speakerEvaluationSetupError {
                    speakerEvaluationResult = .failure(speakerEvaluationSetupError)
                } else {
                    speakerEvaluationResult = .failure(SpeakerAuthenticationError.noSpeakerMatch)
                }
                try Task.checkCancellation()

                if case .success(let evaluation) = speakerEvaluationResult,
                   let match = evaluation.bestMatch,
                   codeMatched {
                    await MainActor.run {
                        self.authenticatedSpeaker = AuthenticatedSpeaker(profile: match.profile, confidence: match.confidence)
                        self.speakerVerificationChallenge = nil
                        self.lastAuthenticationFailureCause = nil
                        self.lastSpeakerScores = evaluation.scores
                        self.speakerAuthenticationStatus = "Authenticated as \(match.profile.displayName) (\(match.profile.accessLevel.displayName))."
                        self.authenticationTask = nil
                    }
                    return
                }

                await MainActor.run {
                    self.authenticatedSpeaker = nil
                    if case .success(let evaluation) = speakerEvaluationResult {
                        self.lastSpeakerScores = evaluation.scores
                    } else {
                        self.lastSpeakerScores = []
                    }
                    self.lastAuthenticationFailureCause = Self.failureCause(
                        speakerEvaluationResult: speakerEvaluationResult,
                        codeMatched: codeMatched
                    )
                    self.rotateSpeakerVerificationChallenge(for: markerName)
                    self.speakerAuthenticationStatus = Self.failureMessage(
                        speakerEvaluationResult: speakerEvaluationResult,
                        codeMatched: codeMatched,
                        transcript: authenticationSample.transcript
                    )
                    self.authenticationTask = nil
                    self.lastAttemptedMarker = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.authenticationTask = nil
                }
            } catch {
                await MainActor.run {
                    self.authenticatedSpeaker = nil
                    self.lastSpeakerScores = []
                    self.lastAuthenticationFailureCause = Self.failureCause(for: error)
                    self.rotateSpeakerVerificationChallenge(for: markerName)
                    self.speakerAuthenticationStatus = error.localizedDescription
                    self.authenticationTask = nil
                    self.lastAttemptedMarker = nil
                }
            }
        }
    }

    private func resetSpeakerAuthentication() {
        authenticationTask?.cancel()
        authenticationTask = nil
        authenticatedSpeaker = nil
        speakerVerificationChallenge = nil
        lastAuthenticationTranscript = nil
        lastAuthenticationFailureCause = nil
        lastSpeakerScores = []
        lastAttemptedMarker = nil
    }

    private func ensureSpeakerVerificationChallenge(for markerName: String) -> SpeakerVerificationChallenge {
        if let existingChallenge = speakerVerificationChallenge,
           existingChallenge.markerName == markerName {
            return existingChallenge
        }

        let challenge = SpeakerVerificationChallenge(markerName: markerName, pincode: Self.generatePincode())
        speakerVerificationChallenge = challenge
        return challenge
    }

    private func rotateSpeakerVerificationChallenge(for markerName: String) {
        speakerVerificationChallenge = SpeakerVerificationChallenge(markerName: markerName, pincode: Self.generatePincode())
    }

    private func markerPolicy(for markerName: String) -> MarkerPolicy {
        markerPolicies[markerName] ?? MarkerPolicy(minimumRole: .public, objectID: PresetObject.cubeGreen.rawValue)
    }

    private static func generatePincode() -> String {
        String(format: "%04d", Int.random(in: 0...9_999))
    }

    private static func failureCause(
        speakerEvaluationResult: Result<SpeakerEvaluation, Error>,
        codeMatched: Bool
    ) -> AuthenticationFailureCause? {
        let speakerMatched: Bool
        switch speakerEvaluationResult {
        case .success(let evaluation):
            speakerMatched = evaluation.bestMatch != nil
        case .failure:
            speakerMatched = false
        }

        switch (speakerMatched, codeMatched) {
        case (true, true):
            return nil
        case (false, true):
            return .identification
        case (true, false):
            return .code
        case (false, false):
            return .identificationAndCode
        }
    }

    private static func failureMessage(
        speakerEvaluationResult: Result<SpeakerEvaluation, Error>,
        codeMatched: Bool,
        transcript: String
    ) -> String {
        switch failureCause(speakerEvaluationResult: speakerEvaluationResult, codeMatched: codeMatched) {
        case .identification:
            if case .failure(let error) = speakerEvaluationResult {
                return error.localizedDescription
            }
            return "Speaker identification failed. Try speaking again."
        case .code:
            return SpeakerAuthenticationError.challengeCodeMismatch(transcript: transcript).localizedDescription
        case .identificationAndCode:
            return "Speaker identification and pincode verification both failed. Try the new code."
        case nil:
            return "Authentication failed."
        }
    }

    private static func failureCause(for error: Error) -> AuthenticationFailureCause? {
        guard let error = error as? SpeakerAuthenticationError else { return nil }

        switch error {
        case .speechRecognitionPermissionDenied,
             .speechRecognitionUnavailable,
             .speechRecognitionFailed,
             .challengeCodeMismatch:
            return .code
        case .picovoiceAccessKeyMissing,
             .eagleSDKNotInstalled,
             .missingReferenceClips,
             .noSpeakerProfilesConfigured,
             .enrollmentFailed,
             .noSpeakerMatch:
            return .identification
        case .microphonePermissionDenied,
             .recordingFailed:
            return .identificationAndCode
        }
    }

    private func refreshSpeakerStatusIfNeeded() {
        guard authenticationMode == .speaker,
              authenticationTask == nil,
              authenticatedSpeaker == nil else { return }
        speakerAuthenticationStatus = speakerModeStatus
    }

    private func speakerProfileIndex(for id: String) -> Int? {
        speakerProfiles.firstIndex { $0.id == id }
    }
}

struct MarkerPolicy: Equatable {
    var minimumRole: AccessLevel
    var objectID: ARObjectID

    init(minimumRole: AccessLevel = .public, objectID: ARObjectID) {
        self.minimumRole = minimumRole
        self.objectID = objectID
    }
}

enum AuthenticationFailureCause: Equatable {
    case identification
    case code
    case identificationAndCode

    var displayName: String {
        switch self {
        case .identification:
            return "Identification"
        case .code:
            return "Code"
        case .identificationAndCode:
            return "Identification + Code"
        }
    }
}

enum MarkerBillboard: Equatable {
    case pincode(String)
    case restricted
}
