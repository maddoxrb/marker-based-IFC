import Foundation
import RealityKit
import ARKit
import SwiftUI

final class ARSceneCoordinator: NSObject, ARSessionDelegate {
    private struct MarkerRuntimeState {
        var anchorIdentifier: UUID?
        var anchorEntity: AnchorEntity?
        var childObjectIDs: [UUID] = []
        var isVisible = false
    }

    private struct ObjectRuntimeState {
        let objectID: ARObjectID
        let markerName: String
    }

    private weak var arView: ARView?
    private let appModel: AppModel
    private let lastDetectedMarker: Binding<String?>
    private let lastDecision: Binding<String>
    private let assetReferenceImages = ARReferenceImage.referenceImages(inGroupNamed: "AR Resources", bundle: .main) ?? []

    private var currentAccessLevel: AccessLevel
    private var markerStates: [String: MarkerRuntimeState] = [:]
    private var objectStates: [UUID: ObjectRuntimeState] = [:]
    private var objectEntities: [UUID: ModelEntity] = [:]
    private var anchorIDToMarkerName: [UUID: String] = [:]
    private var lastKnownMarkerPolicies: [String: MarkerPolicy]
    private var lastConfiguredImageNames: Set<String> = []

    private let baseObjectHeight: Float = 0.02
    private let objectsPerRing = 6
    private let layoutRadiusStep: Float = 0.055
    private let labelChildName = "object-label"

    init(
        appModel: AppModel,
        currentAccessLevel: AccessLevel,
        lastDetectedMarker: Binding<String?>,
        lastDecision: Binding<String>
    ) {
        self.appModel = appModel
        self.currentAccessLevel = currentAccessLevel
        self.lastDetectedMarker = lastDetectedMarker
        self.lastDecision = lastDecision
        self.lastKnownMarkerPolicies = appModel.markerPolicies
        super.init()
    }

    func attach(to arView: ARView) {
        if let currentView = self.arView, currentView === arView {
            return
        }

        self.arView = arView
        arView.automaticallyConfigureSession = false
        arView.session.delegate = self
    }

    func configureSession(runtimeImages: Set<ARReferenceImage>) {
        let images = assetReferenceImages.union(runtimeImages)
        lastConfiguredImageNames = Set(images.compactMap { $0.name })

        guard let arView else { return }

        let configuration = ARImageTrackingConfiguration()
        configuration.isAutoFocusEnabled = true
        configuration.trackingImages = images
        configuration.maximumNumberOfTrackedImages = min(images.count, 4)

        anchorIDToMarkerName.removeAll()
        for markerName in markerStates.keys {
            clearAnchorTracking(for: markerName)
        }

        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func updateReferenceImagesIfNeeded(runtimeImages: Set<ARReferenceImage>) {
        let imageNames = Set(assetReferenceImages.union(runtimeImages).compactMap { $0.name })
        if imageNames != lastConfiguredImageNames {
            configureSession(runtimeImages: runtimeImages)
        }
    }

    func updateAccessLevel(_ level: AccessLevel) {
        guard level != currentAccessLevel else { return }
        currentAccessLevel = level
        refreshAllContentForCurrentRole()

        if let markerName = lastDetectedMarker.wrappedValue {
            lastDecision.wrappedValue = policyDecisionText(for: markerName)
        }
    }

    func syncMarkerPoliciesIfNeeded() {
        let policies = appModel.markerPolicies
        guard policies != lastKnownMarkerPolicies else { return }

        lastKnownMarkerPolicies = policies
        Set(policies.keys).union(markerStates.keys).forEach { ensureMarkerRuntime(for: $0) }
        refreshAllContentForCurrentRole()
    }

    func refreshAllContentForCurrentRole() {
        for objectID in objectStates.keys {
            ensureEntityExists(for: objectID)
            updatePresentation(for: objectID)
        }

        for markerName in markerStates.keys {
            layoutObjects(on: markerName)
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        processImageAnchors(anchors.compactMap { $0 as? ARImageAnchor })
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        processImageAnchors(anchors.compactMap { $0 as? ARImageAnchor })
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        guard !anchors.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            for anchor in anchors {
                let markerName = (anchor as? ARImageAnchor)?.referenceImage.name ?? self.anchorIDToMarkerName[anchor.identifier]
                self.anchorIDToMarkerName.removeValue(forKey: anchor.identifier)
                if let markerName {
                    self.clearAnchorTracking(for: markerName)
                }
            }
        }
    }

    private func processImageAnchors(_ anchors: [ARImageAnchor]) {
        guard !anchors.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            anchors.forEach { self?.handleImageAnchor($0) }
        }
    }

    private func handleImageAnchor(_ imageAnchor: ARImageAnchor) {
        let markerName = imageAnchor.referenceImage.name ?? "(unnamed)"
        ensureMarkerRuntime(for: markerName)

        let replacedAnchor = replaceAnchorIfNeeded(for: markerName, with: imageAnchor)
        let visibilityChanged = updateMarkerVisibility(for: markerName, isVisible: imageAnchor.isTracked)

        if replacedAnchor || visibilityChanged {
            attachObjects(to: markerName)
            layoutObjects(on: markerName)
        }

        lastDetectedMarker.wrappedValue = markerName
        lastDecision.wrappedValue = policyDecisionText(for: markerName)

        if imageAnchor.isTracked, replacedAnchor || visibilityChanged {
            appModel.handleMarkerScan(markerName)
        }
    }

    private func ensureMarkerRuntime(for markerName: String) {
        if markerStates[markerName] == nil {
            markerStates[markerName] = MarkerRuntimeState()
        }
        seedInitialObjectIfNeeded(for: markerName)
    }

    @discardableResult
    private func replaceAnchorIfNeeded(for markerName: String, with imageAnchor: ARImageAnchor) -> Bool {
        guard let arView, var marker = markerStates[markerName] else { return false }
        if marker.anchorIdentifier == imageAnchor.identifier {
            anchorIDToMarkerName[imageAnchor.identifier] = markerName
            return false
        }

        if let previousAnchorIdentifier = marker.anchorIdentifier {
            anchorIDToMarkerName.removeValue(forKey: previousAnchorIdentifier)
        }

        let previousAnchor = marker.anchorEntity
        let anchorEntity = AnchorEntity(anchor: imageAnchor)
        arView.scene.addAnchor(anchorEntity)

        marker.anchorIdentifier = imageAnchor.identifier
        marker.anchorEntity = anchorEntity
        markerStates[markerName] = marker
        anchorIDToMarkerName[imageAnchor.identifier] = markerName

        previousAnchor?.removeFromParent()
        return true
    }

    private func clearAnchorTracking(for markerName: String) {
        guard var marker = markerStates[markerName] else { return }

        if let anchorIdentifier = marker.anchorIdentifier {
            anchorIDToMarkerName.removeValue(forKey: anchorIdentifier)
        }

        marker.isVisible = false
        marker.anchorIdentifier = nil
        marker.anchorEntity?.removeFromParent()
        marker.anchorEntity = nil
        markerStates[markerName] = marker
    }

    @discardableResult
    private func updateMarkerVisibility(for markerName: String, isVisible: Bool) -> Bool {
        guard var marker = markerStates[markerName] else { return false }
        let didChange = marker.isVisible != isVisible
        marker.isVisible = isVisible
        markerStates[markerName] = marker
        return didChange
    }

    private func markerPolicy(for markerName: String) -> MarkerPolicy {
        appModel.markerPolicies[markerName] ?? MarkerPolicy(minimumRole: .public, objectID: PresetObject.cubeGreen.rawValue)
    }

    private func seedInitialObjectIfNeeded(for markerName: String) {
        guard var marker = markerStates[markerName], marker.childObjectIDs.isEmpty else { return }

        let objectID = UUID()
        objectStates[objectID] = ObjectRuntimeState(objectID: markerPolicy(for: markerName).objectID, markerName: markerName)
        marker.childObjectIDs.append(objectID)
        markerStates[markerName] = marker

        ensureEntityExists(for: objectID)
        attachObjects(to: markerName)
        layoutObjects(on: markerName)
    }

    private func attachObjects(to markerName: String) {
        guard let marker = markerStates[markerName], let anchorEntity = marker.anchorEntity else { return }

        for objectID in marker.childObjectIDs {
            ensureEntityExists(for: objectID)
            guard let entity = objectEntities[objectID] else { continue }
            entity.setParent(anchorEntity, preservingWorldTransform: false)
            updatePresentation(for: objectID)
        }
    }

    private func ensureEntityExists(for objectID: UUID) {
        guard objectEntities[objectID] == nil, objectStates[objectID] != nil else { return }

        let entity = ModelEntity()
        entity.name = objectID.uuidString
        objectEntities[objectID] = entity
        updatePresentation(for: objectID)
    }

    private func layoutObjects(on markerName: String) {
        guard let objectIDs = markerStates[markerName]?.childObjectIDs else { return }

        for (index, objectID) in objectIDs.enumerated() {
            objectEntities[objectID]?.transform = layoutTransform(for: index, total: objectIDs.count)
        }
    }

    private func layoutTransform(for index: Int, total: Int) -> Transform {
        guard total > 1 else {
            return Transform(scale: [1, 1, 1], rotation: simd_quatf(), translation: [0, baseObjectHeight, 0])
        }

        let ring = index / objectsPerRing
        let slot = index % objectsPerRing
        let radius = layoutRadiusStep + (Float(ring) * 0.04)
        let angle = (Float(slot) / Float(objectsPerRing)) * (.pi * 2)

        return Transform(
            scale: [1, 1, 1],
            rotation: simd_quatf(),
            translation: [cos(angle) * radius, baseObjectHeight, sin(angle) * radius]
        )
    }

    private func updatePresentation(for objectID: UUID) {
        guard let object = objectStates[objectID], let entity = objectEntities[objectID] else { return }

        entity.isEnabled = markerStates[object.markerName]?.isVisible == true
        guard entity.isEnabled else { return }

        let descriptor = renderDescriptor(for: object)
        entity.model = ModelComponent(mesh: descriptor.mesh, materials: [descriptor.material])
        entity.children.first(where: { $0.name == labelChildName })?.removeFromParent()

        let label = ModelEntity(
            mesh: .generateText(
                descriptor.label,
                extrusionDepth: 0.001,
                font: .systemFont(ofSize: 0.12),
                containerFrame: .zero,
                alignment: .center,
                lineBreakMode: .byWordWrapping
            ),
            materials: [SimpleMaterial(color: .white, roughness: 0.2, isMetallic: false)]
        )
        label.name = labelChildName
        label.position = [0, 0.055, 0]
        entity.addChild(label)
    }

    private func renderDescriptor(for object: ObjectRuntimeState) -> (mesh: MeshResource, material: SimpleMaterial, label: String) {
        let requiredLevel = markerPolicy(for: object.markerName).minimumRole
        guard currentAccessLevel.dominates(requiredLevel) else {
            return (
                .generateBox(size: 0.06, cornerRadius: 0.004),
                SimpleMaterial(color: .red, roughness: 0.3, isMetallic: false),
                "Restricted • \(requiredLevel.displayName)"
            )
        }

        switch object.objectID {
        case PresetObject.cubeGreen.rawValue:
            return (
                .generateBox(size: 0.06, cornerRadius: 0.004),
                SimpleMaterial(color: .green, roughness: 0.2, isMetallic: false),
                "Green Cube • \(requiredLevel.displayName)"
            )
        case PresetObject.coneBlue.rawValue:
            return (
                .generateCone(height: 0.07, radius: 0.035),
                SimpleMaterial(color: .blue, roughness: 0.2, isMetallic: false),
                "Blue Cone • \(requiredLevel.displayName)"
            )
        case PresetObject.spherePurple.rawValue:
            return (
                .generateSphere(radius: 0.035),
                SimpleMaterial(color: .purple, roughness: 0.2, isMetallic: true),
                "Purple Sphere • \(requiredLevel.displayName)"
            )
        case PresetObject.panelRed.rawValue:
            return (
                .generateBox(size: 0.06, cornerRadius: 0.004),
                SimpleMaterial(color: .red, roughness: 0.3, isMetallic: false),
                "Red Panel • \(requiredLevel.displayName)"
            )
        default:
            return (
                .generateBox(size: 0.06, cornerRadius: 0.004),
                SimpleMaterial(color: .gray, roughness: 0.3, isMetallic: false),
                "Unknown • \(requiredLevel.displayName)"
            )
        }
    }

    private func policyDecisionText(for markerName: String) -> String {
        let requiredLevel = markerPolicy(for: markerName).minimumRole
        let objectCount = markerStates[markerName]?.childObjectIDs.count ?? 0

        if currentAccessLevel.dominates(requiredLevel) {
            return "Visible (\(currentAccessLevel.displayName) ≥ \(requiredLevel.displayName), objects: \(objectCount))"
        }

        return "Restricted (\(currentAccessLevel.displayName) < \(requiredLevel.displayName), objects: \(objectCount))"
    }
}
