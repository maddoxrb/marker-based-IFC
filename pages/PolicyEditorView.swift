import SwiftUI

// Add and remove policies from a marker
//
// A production model should authenticate before allowing policy changes,
// for the purposes of this demo I am giving the user admin priveleges (add users/markers, edit users/markers)
struct PolicyEditorView: View {
    @EnvironmentObject var appModel: AppModel

    @State private var selectedMarker: String = ""
    @State private var minimumRole: AccessLevel = .public
    @State private var selectedObject: PresetObject = .cubeGreen

    var body: some View {
        Form {
            Section("Marker") {
                Picker("Marker", selection: $selectedMarker) {
                    ForEach(appModel.availableMarkerNames(), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Access") {
                Picker("Minimum Role", selection: $minimumRole) {
                    ForEach(AccessLevel.allCases, id: \.self) { lvl in
                        Text(lvl.displayName).tag(lvl)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Object") {
                Picker("Object", selection: $selectedObject) {
                    ForEach(PresetObject.allCases) { obj in
                        Text(obj.displayName).tag(obj)
                    }
                }
                .pickerStyle(.menu)
            }

            Section {
                Button {
                    savePolicy()
                } label: {
                    Label("Save Policy", systemImage: "square.and.arrow.down")
                }
                .disabled(selectedMarker.isEmpty)
            }

            if let policy = appModel.markerPolicies[selectedMarker] {
                Section("Preview") {
                    Text("Object: \(PresetObject.displayName(for: policy.objectID))")
                    Text("Minimum Role: \(policy.minimumRole.displayName)")
                }
            }
        }
        .onAppear {
            if selectedMarker.isEmpty { selectedMarker = appModel.availableMarkerNames().first ?? "" }
            if let policy = appModel.markerPolicies[selectedMarker] {
                minimumRole = policy.minimumRole
                if let preset = PresetObject.allCases.first(where: { $0.rawValue == policy.objectID }) {
                    selectedObject = preset
                }
            }
        }
        .onChange(of: selectedMarker) { _, newValue in
            if let policy = appModel.markerPolicies[newValue] {
                minimumRole = policy.minimumRole
                if let preset = PresetObject.allCases.first(where: { $0.rawValue == policy.objectID }) {
                    selectedObject = preset
                }
            }
        }
    }

    // TODO: This UI is not very responsive, need to fix at some point
    private func savePolicy() {
        guard !selectedMarker.isEmpty else { return }
        appModel.setPolicy(for: selectedMarker, minimumRole: minimumRole, objectID: selectedObject.rawValue)
    }
}

struct PolicyManagementView: View {
    @EnvironmentObject var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Marker Policy Management")
                .font(.title3)
                .bold()
                .padding(.horizontal)
            PolicyEditorView()
                .environmentObject(appModel)
            Spacer(minLength: 0)
        }
        .navigationTitle("Policies")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PolicyEditorScreen: View {
    @EnvironmentObject var appModel: AppModel

    var body: some View {
        NavigationView {
            PolicyEditorView()
                .environmentObject(appModel)
                .navigationTitle("Policy Editor")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}
