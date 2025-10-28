import SwiftUI

/// Global notice types that can be displayed to the user
enum AppNotice: Equatable {
    case tunnelDisabled
    case appNeedsUpdate
    
    var title: String {
        switch self {
        case .tunnelDisabled:
            return "Connection Failed"
        case .appNeedsUpdate:
            return "Update Required"
        }
    }
    
    var message: String {
        switch self {
        case .tunnelDisabled:
            return "Unable to reach your Goose agent. Please enable tunneling in the Goose desktop app."
        case .appNeedsUpdate:
            return "The desktop app needs to be updated to work with this version of the mobile app."
        }
    }
    
    var icon: String {
        switch self {
        case .tunnelDisabled:
            return "network.slash"
        case .appNeedsUpdate:
            return "arrow.down.circle"
        }
    }
}

/// Shared global state for displaying app-wide notices
class AppNoticeCenter: ObservableObject {
    static let shared = AppNoticeCenter()
    
    @Published var activeNotice: AppNotice?
    
    private init() {}
    
    /// Set a notice to be displayed
    func setNotice(_ notice: AppNotice) {
        DispatchQueue.main.async {
            self.activeNotice = notice
        }
    }
    
    /// Clear the current notice
    func clearNotice() {
        DispatchQueue.main.async {
            self.activeNotice = nil
        }
    }
}
