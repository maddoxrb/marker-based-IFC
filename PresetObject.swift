import Foundation

// Preset objects for demo
// Any object can be attatched to a marker

enum PresetObject: String, CaseIterable, Identifiable {
    case cubeGreen = "markerA-shared"
    case coneBlue = "markerB-employee"
    case spherePurple = "markerB-admin"
    case panelRed = "restricted-panel"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cubeGreen: return "Green Cube"
        case .coneBlue: return "Blue Cone"
        case .spherePurple: return "Purple Sphere"
        case .panelRed: return "Red Panel"
        }
    }
}
