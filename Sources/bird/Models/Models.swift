import Foundation

enum CaptureSourceKind: String, CaseIterable, Identifiable {
    case display
    case window

    var id: String { rawValue }
    var label: String {
        switch self {
        case .display: return "Entire Display"
        case .window: return "Single Window"
        }
    }
}

struct CaptureSource: Identifiable, Hashable {
    let id: String
    let label: String
}

struct InputDevice: Identifiable, Hashable {
    let id: String
    let name: String
}
