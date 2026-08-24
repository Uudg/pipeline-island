import Foundation

/// Which pipelines the island watches.
public enum PipelineScope: String, Sendable, CaseIterable, Codable {
    /// Only projects in the signed-in user's own namespace.
    case mine
    /// Projects belonging to the groups the user has selected.
    case groups
    /// Every project the user is a member of. The original behaviour.
    case all

    public var label: String {
        switch self {
        case .mine: return "My projects only"
        case .groups: return "Selected organizations"
        case .all: return "Everything I have access to"
        }
    }

    public var detail: String {
        switch self {
        case .mine: return "Projects in your own namespace."
        case .groups: return "Projects belonging to the groups you pick below."
        case .all: return "Every project you are a member of, personal and organizational."
        }
    }
}

/// Whose pipeline runs to show, independent of *which projects* are watched.
public enum PipelineAuthorScope: String, Sendable, CaseIterable, Codable {
    /// Only runs the signed-in user triggered.
    case me
    /// Every run, whoever started it.
    case everyone

    public var label: String {
        switch self {
        case .me: return "Only pipelines I triggered"
        case .everyone: return "Pipelines from everyone"
        }
    }

    public var detail: String {
        switch self {
        case .me: return "Your own pushes and manual runs. Colleagues' runs are hidden."
        case .everyone: return "Every run in the projects above, whoever started it."
        }
    }
}

/// A group the user belongs to, for the organization picker.
public struct GitLabGroup: Codable, Sendable, Hashable, Identifiable {
    public let fullPath: String
    public let name: String
    public let projectsCount: Int?

    public var id: String { fullPath }

    public init(fullPath: String, name: String, projectsCount: Int? = nil) {
        self.fullPath = fullPath
        self.name = name
        self.projectsCount = projectsCount
    }
}
