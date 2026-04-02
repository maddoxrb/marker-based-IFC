import Foundation
import SwiftUI
import Combine
import ARKit

typealias ARObjectID = String

// Manages all app state, including marker policies, speaker profiles, 
// and authentication status. Shared as an environment object across pages
// For actual UI see /pages

final class AppModel: ObservableObject {
    private static let speakerProfilesStorageKey = "speaker_profiles"
    private static let manualModeMessage = "Manual role selection controls visibility."
    private static let noSpeakerProfilesMessage = "No enrolled speakers configured. Add one in Manage Speakers."
    private static let readyForSpeakerMessage = "Scan a marker, then speak to authenticate."
    static let voiceRecordingDuration: TimeInterval = 10 // 10 seems to be the best balance for identification

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

    private let speakerAuthenticator: any SpeakerAuthenticating
    private let voiceSampleRecorder: any VoiceSampleRecording
    private var authenticationTask: Task<Void, Never>?
    private var lastObservedMarker: String?
    private var lastAttemptedMarker: String?

    init(
        speakerAuthenticator: (any SpeakerAuthenticating)? = nil,
        voiceSampleRecorder: (any VoiceSampleRecording)? = nil
    ) {
        speakerProfiles = Self.loadSpeakerProfiles()
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
        guard authenticationMode == .speaker,
              authenticatedSpeaker == nil,
              authenticationTask == nil,
              lastAttemptedMarker != markerName else { return }
        startSpeakerAuthentication(for: markerName)
    }

    // TODO: May want to change this logic, currenty must rescan marker after failure
    func retrySpeakerAuthentication() {
        guard let lastObservedMarker else {
            speakerAuthenticationStatus = "Scan a marker before retrying voice authentication."
            return
        }
        startSpeakerAuthentication(for: lastObservedMarker, force: true)
    }

    func clearSpeakerAuthentication() {
        resetSpeakerAuthentication()
        speakerAuthenticationStatus = speakerProfiles.isEmpty? Self.noSpeakerProfilesMessage: "Authentication cleared. Scan a marker, then speak to authenticate."
    }

    func addSpeakerProfile(name: String, accessLevel: AccessLevel) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        speakerProfiles.append(SpeakerProfile(id: UUID().uuidString, displayName: name, accessLevel: accessLevel, referenceClipNames: []))
        persistSpeakerProfiles()
        refreshSpeakerStatusIfNeeded()
    }

    func updateSpeakerProfile(id: String, name: String, accessLevel: AccessLevel) {
        guard let index = speakerProfileIndex(for: id) else { return }

        speakerProfiles[index].displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        speakerProfiles[index].accessLevel = accessLevel
        persistSpeakerProfiles()
    }

    func deleteSpeakerProfile(id: String) {
        guard let index = speakerProfileIndex(for: id) else { return }

        let deletedProfile = speakerProfiles.remove(at: index)
        deletedProfile.referenceClipNames.forEach(SpeakerClipStore.deleteClip(named:))
        if authenticatedSpeaker?.profile.id == deletedProfile.id {
            authenticatedSpeaker = nil
        }

        persistSpeakerProfiles()
        refreshSpeakerStatusIfNeeded()
    }

    func deleteSpeakerClip(_ clipName: String, from profileID: String) {
        guard let index = speakerProfileIndex(for: profileID) else { return }

        speakerProfiles[index].referenceClipNames.removeAll { $0 == clipName }
        SpeakerClipStore.deleteClip(named: clipName)
        persistSpeakerProfiles()
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

        persistSpeakerProfiles()
        refreshSpeakerStatusIfNeeded()
    }

    private var speakerModeStatus: String {
        speakerProfiles.isEmpty ? Self.noSpeakerProfilesMessage : Self.readyForSpeakerMessage
    }

    private func startSpeakerAuthentication(for markerName: String, force: Bool = false) {
        guard authenticationMode == .speaker else { return }
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

        lastAttemptedMarker = markerName
        speakerAuthenticationStatus = "Speak now to authenticate for \(markerName)."

        authenticationTask = Task { [weak self] in
            guard let self else { return }

            do {
                let sampleURL = try await self.voiceSampleRecorder.recordSample(duration: Self.voiceRecordingDuration)
                try Task.checkCancellation()

                await MainActor.run {
                    self.speakerAuthenticationStatus = "Matching voice sample for \(markerName)..."
                }

                let match = try await self.speakerAuthenticator.matchSpeaker(sampleURL: sampleURL, against: self.speakerProfiles)
                try Task.checkCancellation()

                await MainActor.run {
                    self.authenticatedSpeaker = AuthenticatedSpeaker(profile: match.profile, confidence: match.confidence)
                    self.speakerAuthenticationStatus = "Authenticated as \(match.profile.displayName) (\(match.profile.accessLevel.displayName))."
                    self.authenticationTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.authenticationTask = nil
                }
            } catch {
                await MainActor.run {
                    self.authenticatedSpeaker = nil
                    self.speakerAuthenticationStatus = error.localizedDescription
                    self.authenticationTask = nil
                }
            }
        }
    }

    private func resetSpeakerAuthentication() {
        authenticationTask?.cancel()
        authenticationTask = nil
        authenticatedSpeaker = nil
        lastAttemptedMarker = nil
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

    private func persistSpeakerProfiles() {
        guard let encodedProfiles = try? JSONEncoder().encode(speakerProfiles) else { return }
        UserDefaults.standard.set(encodedProfiles, forKey: Self.speakerProfilesStorageKey)
    }

    private static func loadSpeakerProfiles() -> [SpeakerProfile] {
        guard let storedProfiles = UserDefaults.standard.data(forKey: speakerProfilesStorageKey) else { return [] }
        return (try? JSONDecoder().decode([SpeakerProfile].self, from: storedProfiles)) ?? []
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
