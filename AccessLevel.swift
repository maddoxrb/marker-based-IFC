import Foundation

// For the project demo, I have limited the authority hierarchy to three roles:
// 1. Public
// 2. Employee
// 3. Admin
// Markers can be designated accessible by any of these authority roles,
// individual users can be assigned any of the three roles

enum AccessLevel: Int, CaseIterable, Codable, Comparable, Equatable, Hashable {
    case `public` = 0
    case employee = 1
    case admin = 2

    var displayName: String {
        switch self {
        case .public: return "Public"
        case .employee: return "Employee"
        case .admin: return "Admin"
        }
    }

    // A partial order is necessary for IFC, for the demo it is:
    //  public < employee < admin
    func dominates(_ other: AccessLevel) -> Bool {
        self >= other
    }

    static func < (lhs: AccessLevel, rhs: AccessLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
