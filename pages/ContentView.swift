import SwiftUI

// Home screen for app, includes: AR view, access to policy pages, marker-based info

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var lastDetectedMarker: String? = nil
    @State private var lastDecision: String = ""
    @State private var showMarkerSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                MarkerTrackingView(lastDetectedMarker: $lastDetectedMarker,
                                   lastDecision: $lastDecision)
                    .environmentObject(appModel)
                    .edgesIgnoringSafeArea(.all)

                // Control panel for role selection, detection info, and quick actions
                VStack(spacing: 8) {
                    Text("AR-IFC Sandbox")
                        .font(.headline)

                    Picker("Auth Mode", selection: $appModel.authenticationMode) {
                        ForEach(AuthenticationMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if appModel.authenticationMode == .manual {
                        Picker("Role", selection: $appModel.currentAccessLevel) {
                            ForEach(AccessLevel.allCases, id: \.self) { lvl in
                                Text(lvl.displayName).tag(lvl)
                            }
                        }
                        .pickerStyle(.segmented)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Registered speakers:")
                                .fontWeight(.semibold)
                            if appModel.speakerProfiles.isEmpty {
                                Text("No registered speakers.")
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                ForEach(appModel.speakerProfiles) { profile in
                                    Text(speakerPanelSummary(for: profile))
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                            Text("Voice auth: \(appModel.speakerAuthenticationStatus)")
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Identity: \(appModel.activeIdentitySummary)")
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Failure cause: \(appModel.lastAuthenticationFailureCause?.displayName ?? "—")")
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Transcript: \(appModel.lastAuthenticationTranscript?.isEmpty == false ? appModel.lastAuthenticationTranscript! : "—")")
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            if appModel.isSpeakerAuthenticationInProgress {
                                ProgressView()
                                    .progressViewStyle(.linear)
                            }
                            Button("Retry Voice Authentication") {
                                appModel.retrySpeakerAuthentication()
                            }
                            .buttonStyle(.bordered)
                            Button("Clear Authentication") {
                                appModel.clearSpeakerAuthentication()
                            }
                            .buttonStyle(.bordered)
                        }
                        .font(.footnote)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Detection + decision
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            if let marker = lastDetectedMarker {
                                Text("Detected marker: \(marker)")
                            } else {
                                Text("Detected marker: —")
                            }
                            Text("Decision: \(lastDecision.isEmpty ? "—" : lastDecision)")
                        }
                        .font(.footnote)
                        Spacer()
                    }
                    .padding(.horizontal)

                    // nav for marker and policy pages
                    HStack {
                        Button { showMarkerSheet = true } label: {
                            Label("Add Marker", systemImage: "qrcode.viewfinder")
                        }
                        Spacer()
                        NavigationLink {
                            SpeakerManagementView()
                                .environmentObject(appModel)
                        } label: {
                            Label("Manage Speakers", systemImage: "waveform")
                        }
                        Spacer()
                        NavigationLink {
                            PolicyManagementView()
                                .environmentObject(appModel)
                        } label: {
                            Label("Manage Policies", systemImage: "slider.horizontal.3")
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showMarkerSheet) {
            AddMarkerSheet()
                .environmentObject(appModel)
        }
    }

    private func speakerPanelSummary(for profile: SpeakerProfile) -> String {
        let scoreText: String
        if let score = appModel.lastSpeakerScores.first(where: { $0.profileID == profile.id }) {
            scoreText = score.score.formatted(.number.precision(.fractionLength(3)))
        } else {
            scoreText = "—"
        }

        return "\(profile.displayName) (\(profile.accessLevel.displayName), clips: \(profile.referenceClipNames.count)) score: \(scoreText)"
    }
}
