import SwiftUI
import PhotosUI
import ARKit

// Upload marker images
// Default size is 5cm, very important to put a correct estimate for any new marker
// ARKit seems to be very finnicky if widths do not align
struct AddMarkerSheet: View {
    @EnvironmentObject var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var selectedImage: UIImage? = nil
    @State private var name: String = ""
    @State private var physicalWidthCM: String = "5.0" // default 5 cm

    var body: some View {
        NavigationStack {
            Form {
                Section("Marker Image") {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Choose Image", systemImage: "photo")
                    }
                    if let uiImage = selectedImage {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                Section("Details") {
                    TextField("Marker Name", text: $name)
                    TextField("Physical width in *(cm)*", text: $physicalWidthCM)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle("Add Marker")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addMarker() }
                        .disabled(selectedImage == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: pickerItem) { _, newValue in
                Task { await loadImage(from: newValue) }
            }
        }
    }

    private func loadImage(from item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
            await MainActor.run {
                self.selectedImage = image
                if self.name.isEmpty { self.name = defaultName(from: item) }
            }
        }
    }

    // auto default to a rand name
    private func defaultName(from item: PhotosPickerItem) -> String {
        return "Marker_\(Int(Date().timeIntervalSince1970))"
    }

    private func addMarker() {
        guard let uiImage = selectedImage, let cg = uiImage.cgImage else { return }
        let cm = Double(physicalWidthCM) ?? 5.0
        let meters = CGFloat(cm / 100.0)
        appModel.addMarkerImage(name: name, cgImage: cg, physicalWidthMeters: meters)
        dismiss()
    }
}
