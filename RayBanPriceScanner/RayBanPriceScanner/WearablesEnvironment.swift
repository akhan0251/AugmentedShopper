import Foundation
import MWDATCore

@MainActor
final class WearablesEnvironment {
    static let shared = WearablesEnvironment()

    let wearables: WearablesInterface
    let wearablesViewModel: WearablesViewModel
    let streamSessionViewModel: StreamSessionViewModel

    private init() {
        // If your SDK exposes a different entry point than `Wearables.shared`,
        // swap in the initializer that matches your installed MWDAT version.
        let wearablesInstance = Wearables.shared

        self.wearables = wearablesInstance
        self.wearablesViewModel = WearablesViewModel(wearables: wearablesInstance)
        self.streamSessionViewModel = StreamSessionViewModel(wearables: wearablesInstance)
    }
}
