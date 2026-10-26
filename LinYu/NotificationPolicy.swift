import Foundation

enum NotificationKind: String {
    case inUse, finished, autoClosed, closeProblem, openFailed, occupied
    func enabled(master: Bool, inUse: Bool, finished: Bool, autoClose: Bool) -> Bool {
        guard master else { return false }
        switch self {
        case .inUse: return inUse
        case .finished, .closeProblem: return finished
        case .autoClosed: return autoClose
        case .openFailed, .occupied: return true
        }
    }
    var urgent: Bool { self == .autoClosed || self == .closeProblem || self == .openFailed || self == .occupied }
    var destination: Int { self == .finished || self == .autoClosed ? 1 : 0 }
}
