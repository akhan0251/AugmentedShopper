import Foundation
import CoreGraphics
import Combine
import UIKit
import MWDATCore

@MainActor
final class WearablesBridge: ObservableObject {
    static let shared = WearablesBridge()

    let frameSubject = PassthroughSubject<CGImage, Never>()

    let wearablesViewModel: WearablesViewModel
    let streamSessionViewModel: StreamSessionViewModel

    private var frameCancellable: AnyCancellable?

    private init() {
        let env = WearablesEnvironment.shared
        self.wearablesViewModel = env.wearablesViewModel
        self.streamSessionViewModel = env.streamSessionViewModel

        frameCancellable = streamSessionViewModel.$currentVideoFrame
            .compactMap { $0?.cgImage }
            .sink { [weak self] cgImage in
                self?.frameSubject.send(cgImage)
            }
    }

    func connectGlasses() {
        wearablesViewModel.connectGlasses()
    }

    func disconnectGlasses() {
        wearablesViewModel.disconnectGlasses()
    }

    func startStreaming() async {
        await streamSessionViewModel.handleStartStreaming()
    }

    func stopStreaming() {
        streamSessionViewModel.stopSession()
    }

    func startFreshDebugStream() async {
        await streamSessionViewModel.startFreshStream()
    }
}
