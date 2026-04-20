import Foundation

// Preset objects for demo
// Any object can be attatched to a marker

enum PresetObject: String, CaseIterable, Identifiable {
    case cubeGreen = "green-cube"
    case coneBlue = "blue-cone"
    case spherePurple = "purple-sphere"
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

    static func displayName(for objectID: String) -> String {
        PresetObject.allCases.first(where: { $0.rawValue == objectID })?.displayName ?? objectID
    }
}
