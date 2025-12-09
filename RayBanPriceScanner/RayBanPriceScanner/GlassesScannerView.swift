import SwiftUI
import Vision

struct GlassesScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var wearablesBridge = WearablesBridge.shared

    @State private var hasDetectedCode = false

    var onDetect: (String) -> Void

    var body: some View {
        ZStack {
            if let uiImage = wearablesBridge.streamSessionViewModel.currentVideoFrame {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                ProgressView("Waiting for video from glasses…")
            }

            VStack {
                HStack {
                    Spacer()
                    Button("Close") {
                        wearablesBridge.stopStreaming()
                        dismiss()
                    }
                    .padding()
                    .background(.black.opacity(0.5))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Spacer()
            }
            .padding()
        }
        .task {
            await wearablesBridge.startStreaming()
        }
        .onChange(of: wearablesBridge.streamSessionViewModel.currentVideoFrame) { _, newImage in
            guard !hasDetectedCode,
                  let newImage,
                  let cgImage = newImage.cgImage else { return }
            detectBarcode(in: cgImage)
        }
    }

    private func detectBarcode(in cgImage: CGImage) {
        let request = VNDetectBarcodesRequest { request, _ in
            if let obs = request.results?.compactMap({ $0 as? VNBarcodeObservation }).first,
               let payload = obs.payloadStringValue {
                handleDetected(code: payload)
            }
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        try? handler.perform([request])
    }

    private func handleDetected(code: String) {
        guard !hasDetectedCode else { return }
        hasDetectedCode = true

        Task { @MainActor in
            wearablesBridge.stopStreaming()
            onDetect(code)
            dismiss()
        }
    }
}
