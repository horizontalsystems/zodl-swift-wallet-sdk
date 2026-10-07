import Foundation

/// Owns cancellation of preparation while preserving work already admitted to native creation.
final class GiftCardOperationAdmission {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?
    private var requested = false
    private var nativeAdmitted = false

    func installCancellation(_ cancellation: @escaping () -> Void) {
        lock.lock()
        self.cancellation = cancellation
        let shouldCancel = requested && !nativeAdmitted
        lock.unlock()
        if shouldCancel { cancellation() }
    }

    func requestCancellation() {
        lock.lock()
        requested = true
        let cancellation = nativeAdmitted ? nil : self.cancellation
        lock.unlock()
        cancellation?()
    }

    func markNativeAdmission() {
        lock.lock()
        nativeAdmitted = true
        lock.unlock()
    }
}
