import SwiftUI
import RealityKit

// view for marking tracking info, shows marker scans, auth levels

struct MarkerTrackingView: UIViewRepresentable {
    @Binding var lastDetectedMarker: String?
    @Binding var lastDecision: String

    @EnvironmentObject private var appModel: AppModel

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        context.coordinator.attach(to: arView)
        context.coordinator.configureSession(runtimeImages: appModel.runtimeReferenceImages)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.updateAccessLevel(appModel.effectiveAccessLevel)
        context.coordinator.updateReferenceImagesIfNeeded(runtimeImages: appModel.runtimeReferenceImages)
        context.coordinator.syncMarkerPoliciesIfNeeded()
    }

    func makeCoordinator() -> ARSceneCoordinator {
        ARSceneCoordinator(appModel: appModel,currentAccessLevel: appModel.effectiveAccessLevel, lastDetectedMarker: $lastDetectedMarker, lastDecision: $lastDecision)
    }
}
