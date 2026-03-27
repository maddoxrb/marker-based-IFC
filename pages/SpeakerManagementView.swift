import SwiftUI

// Allows for the upload of voice clips for voice recognition
// Credit to https://github.com/pinlunhuang/Voice-Recorder for voice recording and UI logic

struct SpeakerManagementView: View {
    @EnvironmentObject var appModel: AppModel
    @State private var isShowingAddSpeakerSheet = false

    var body: some View {
        List {
            if appModel.speakerProfiles.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No speakers configured")
                            .font(.headline)
                        Text("Add a speaker, assign an access level, and record ideally 2-3 clips")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            } else {
                ForEach(appModel.speakerProfiles) { profile in
                    NavigationLink {
                        SpeakerDetailView(profileID: profile.id)
                            .environmentObject(appModel)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.displayName)
                                .font(.headline)
                            Text("Level: \(profile.accessLevel.displayName)")
                                .font(.subheadline)
                            Text("Clips: \(profile.referenceClipNames.count)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .onDelete(perform: deleteSpeakers)
            }
        }
        .navigationTitle("Speakers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingAddSpeakerSheet = true
                } label: {
                    Label("Add Speaker", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isShowingAddSpeakerSheet) {
            NavigationStack {
                AddSpeakerView()
                    .environmentObject(appModel)
            }
        }
    }

    private func deleteSpeakers(at offsets: IndexSet) {
        for index in offsets {
            let profileID = appModel.speakerProfiles[index].id
            appModel.deleteSpeakerProfile(id: profileID)
        }
    }
}

private struct AddSpeakerView: View {
    @EnvironmentObject var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var accessLevel: AccessLevel = .public

    var body: some View {
        Form {
            Section("Speaker") {
                TextField("Display Name", text: $name)

                Picker("Access Level", selection: $accessLevel) {
                    ForEach(AccessLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("Add Speaker")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    appModel.addSpeakerProfile(name: name, accessLevel: accessLevel)
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private struct SpeakerDetailView: View {
    @EnvironmentObject var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let profileID: String

    @State private var editedName = ""
    @State private var editedAccessLevel: AccessLevel = .public
    @State private var isRecording = false
    @State private var statusMessage = ""

    private var profile: SpeakerProfile? {
        appModel.speakerProfiles.first(where: { $0.id == profileID })
    }

    var body: some View {
        Form {
            if let profile {
                Section("Speaker") {
                    TextField("Display Name", text: $editedName)

                    Picker("Access Level", selection: $editedAccessLevel) {
                        ForEach(AccessLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)

                    Button("Save Changes") {
                        appModel.updateSpeakerProfile(id: profileID,name: editedName,accessLevel: editedAccessLevel)
                        statusMessage = "Speaker details saved."
                    }
                }

                Section("Enrollment Clips") {
                    if profile.referenceClipNames.isEmpty {
                        Text("No clips recorded yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(profile.referenceClipNames, id: \.self) { clipName in
                            HStack {
                                Text(clipName)
                                    .font(.footnote)
                                    .lineLimit(1)
                                Spacer()
                                Button(role: .destructive) {
                                    appModel.deleteSpeakerClip(clipName, from: profileID)
                                    statusMessage = "Deleted clip."
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                    }

                    Button(isRecording ? "Recording \(Int(AppModel.voiceRecordingDuration))s Clip..." : "Record New Clip") {
                        recordClip()
                    }
                    .disabled(isRecording)
                }

                if !statusMessage.isEmpty {
                    Section("Status") {
                        Text(statusMessage)
                            .font(.footnote)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        appModel.deleteSpeakerProfile(id: profileID)
                        dismiss()
                    } label: {
                        Label("Delete Speaker", systemImage: "trash")
                    }
                }
            } else {
                Section {
                    Text("Speaker not found.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(profile?.displayName ?? "Speaker")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: syncEditorFields)
        .onChange(of: appModel.speakerProfiles) { _, _ in
            syncEditorFields()
        }
    }

    private func syncEditorFields() {
        guard let profile else { return }
        editedName = profile.displayName
        editedAccessLevel = profile.accessLevel
    }

    private func recordClip() {
        isRecording = true
        statusMessage = "Recording clip..."

        Task {
            do {
                try await appModel.recordSpeakerClip(for: profileID)
                await MainActor.run {
                    statusMessage = "Clip recorded successfully."
                    isRecording = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = error.localizedDescription
                    isRecording = false
                }
            }
        }
    }
}
