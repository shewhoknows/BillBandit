import Foundation

actor SessionState {
    private(set) var currentUser: UserProfile?

    func setCurrentUser(_ user: UserProfile?) {
        currentUser = user
    }

    func clear() {
        currentUser = nil
    }
}
