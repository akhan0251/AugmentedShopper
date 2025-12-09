import SwiftUI
import Photos
import Combine
import MWDATCore
import Vision

struct LiveStreamView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var wearablesBridge = WearablesBridge.shared
    @State private var saveMessage: String = ""
    @State private var isSaving = false
    @State private var statusText: String = "Stopped"
    @State private var errorText: String?
    @State private var showRegistration = false
    @State private var latestFrame: UIImage?
    @State private var frameResolution: String = "—"
    @State private var frameFPS: Double = 0
    @State private var autoStillEnabled = false
    @State private var autoStillTriggered = false
    @State private var showDebugOverlay = false
    @State private var frameTimestamps: [Date] = []
    @State private var frameRateSelection: FrameRatePreset = .high
    @State private var barcodeBoxes: [CGRect] = []
    @State private var lastBarcodeDetect = Date.distantPast
    @State private var lastOverlayCode: String?
    @State private var overlayPriceText: String?
    @State private var overlayLookupTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                videoSurface
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    topOverlay

                    Spacer()

                    bottomPanel
                        .padding(.horizontal, 16)
                        .padding(.bottom, proxy.safeAreaInsets.bottom + 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, proxy.safeAreaInsets.top + 8)
            }
            .ignoresSafeArea(.container, edges: .vertical)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            Task {
                if wearablesBridge.wearablesViewModel.registrationState == .registered {
                    if !wearablesBridge.streamSessionViewModel.isStreaming {
                        await wearablesBridge.startStreaming()
                    }
                } else {
                    showRegistration = true
                    errorText = "Glasses not registered. Open registration."
                }
            }
        }
        .onDisappear {
            wearablesBridge.stopStreaming()
        }
        .onReceive(wearablesBridge.wearablesViewModel.$registrationState) { state in
            if state == .registered {
                Task {
                    if !wearablesBridge.streamSessionViewModel.isStreaming {
                        await wearablesBridge.startStreaming()
                    }
                }
            } else {
                wearablesBridge.stopStreaming()
                showRegistration = true
            }
        }
        .onReceive(wearablesBridge.streamSessionViewModel.$streamingStatus) { status in
            switch status {
            case .streaming: statusText = "Streaming"
            case .waiting: statusText = "Waiting"
            case .stopped: statusText = "Stopped"
            }
        }
        .onReceive(wearablesBridge.streamSessionViewModel.$frameRatePreset) { preset in
            frameRateSelection = preset
        }
        .onReceive(wearablesBridge.streamSessionViewModel.$errorMessage) { message in
            guard wearablesBridge.streamSessionViewModel.showError, !message.isEmpty else { return }
            errorText = message
        }
        .onReceive(wearablesBridge.frameSubject.receive(on: RunLoop.main)) { cgImage in
            updateFrameMetrics(with: cgImage)
            if autoStillEnabled, !autoStillTriggered {
                autoStillTriggered = true
                Task { await wearablesBridge.streamSessionViewModel.captureHighQualityFrame() }
            }
            latestFrame = UIImage(cgImage: cgImage)
            runBarcodeOverlayDetection(on: cgImage)
        }
        .sheet(isPresented: $showRegistration) {
            RegistrationView(viewModel: wearablesBridge.wearablesViewModel)
        }
    }

    private var frameRatePicker: some View {
        Picker("Frame rate", selection: $frameRateSelection) {
            ForEach(FrameRatePreset.allCases) { preset in
                Text(preset.label).tag(preset)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: frameRateSelection) { _, newValue in
            Task {
                await wearablesBridge.streamSessionViewModel.updateFrameRatePresetAsync(newValue)
            }
        }
    }

    @ViewBuilder
    private var videoSurface: some View {
        ZStack {
            Color.black

            if let frame = latestFrame ?? wearablesBridge.streamSessionViewModel.currentVideoFrame {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: frame)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        if showDebugOverlay {
                            debugInfoOverlay
                        }
                        barcodeOverlay
                    }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Waiting for video from glasses…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 20)
            }

            LinearGradient(
                colors: [
                    Color.black.opacity(0.45),
                    Color.black.opacity(0.1),
                    Color.black.opacity(0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var topOverlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.85))
                .foregroundColor(.black)

                Spacer()
            }

            combinedStatusBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .foregroundColor(.white)
    }

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            actionRow

            if !saveMessage.isEmpty {
                Text(saveMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.95)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.35),
                            Color.white.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.3), radius: 22, x: 0, y: 16)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
    }

    private var actionRow: some View {
        VStack(spacing: 10) {
            // First row: core controls + FPS menu
            HStack(spacing: 12) {
                Button {
                    Task {
                        if wearablesBridge.wearablesViewModel.registrationState != .registered {
                            errorText = "Glasses not registered. Open registration first."
                            showRegistration = true
                            return
                        }
                        errorText = nil
                        autoStillTriggered = false
                        await wearablesBridge.startStreaming()
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.green.opacity(0.9))

                Button {
                    wearablesBridge.stopStreaming()
                    autoStillTriggered = false
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Color.red.opacity(0.9))

                Menu {
                    ForEach(FrameRatePreset.allCases) { preset in
                        Button(preset.label) {
                            frameRateSelection = preset
                            Task { await wearablesBridge.streamSessionViewModel.updateFrameRatePresetAsync(preset) }
                        }
                    }
                } label: {
                    Image(systemName: "speedometer")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.blue.opacity(0.9))
            }
            .frame(height: 44)

            // Second row: capture/save/reset + toggle
            HStack(spacing: 12) {
                Button {
                    Task { await wearablesBridge.streamSessionViewModel.captureHighQualityFrame() }
                } label: {
                    Image(systemName: "camera.aperture")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Color.mint.opacity(0.9))

                Toggle(isOn: $autoStillEnabled) {
                    Image(systemName: autoStillEnabled ? "camera.badge.clock" : "camera")
                }
                .toggleStyle(.button)
                .tint(Color.mint.opacity(0.9))
                .frame(maxWidth: .infinity)
                .onChange(of: autoStillEnabled) { _, isOn in
                    if isOn { autoStillTriggered = false }
                }

                Button {
                    saveCurrentFrame()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Color.orange.opacity(0.9))
                .disabled(isSaving || (latestFrame ?? wearablesBridge.streamSessionViewModel.currentVideoFrame) == nil)

                Button {
                    Task { await wearablesBridge.streamSessionViewModel.resetSessionForUser() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Color.gray.opacity(0.9))
                .accessibilityLabel("Reset stream session")
            }
            .frame(height: 44)
        }
        .controlSize(.regular)
    }

    private var combinedStatusBar: some View {
        let isStreaming = statusText == "Streaming"
        return HStack(spacing: 10) {
            Label(statusText, systemImage: isStreaming ? "dot.radiowaves.left.and.right" : "pause.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(isStreaming ? Color.red : Color.white.opacity(0.9), Color.white)
            Label(frameResolution, systemImage: "camera.viewfinder")
            Label(String(format: "%.1f fps", frameFPS), systemImage: "speedometer")
            Label(autoStillEnabled ? "Auto still" : "Manual", systemImage: autoStillEnabled ? "camera.badge.clock" : "camera")
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.35))
        .clipShape(Capsule())
    }

    private func saveCurrentFrame() {
        guard let image = latestFrame ?? wearablesBridge.streamSessionViewModel.currentVideoFrame else { return }
        isSaving = true
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        saveMessage = "Saved to Photos."
        isSaving = false
    }

    private func updateFrameMetrics(with cgImage: CGImage) {
        frameResolution = "\(cgImage.width)x\(cgImage.height)"
        let now = Date()
        frameTimestamps.append(now)
        frameTimestamps = frameTimestamps.filter { now.timeIntervalSince($0) < 1.0 }
        if frameTimestamps.count > 1 {
            let span = frameTimestamps.last!.timeIntervalSince(frameTimestamps.first!)
            if span > 0 {
                frameFPS = Double(frameTimestamps.count - 1) / span
            }
        }
    }

    private func runBarcodeOverlayDetection(on cgImage: CGImage) {
        let now = Date()
        guard now.timeIntervalSince(lastBarcodeDetect) > 0.4 else { return }
        lastBarcodeDetect = now

        Task.detached(priority: .utility) {
            let result = detectBarcodeRectsAndPayload(in: cgImage)
            await MainActor.run {
                self.barcodeBoxes = result.boxes
                if let code = result.payload, code != lastOverlayCode {
                    lastOverlayCode = code
                    NotificationCenter.default.post(name: .didDetectCode, object: code)
                    overlayPriceText = "Looking up…"
                    overlayLookupTask?.cancel()
                    overlayLookupTask = Task {
                        let info = try? await ProductLookupService.shared.lookup(upc: code)
                        await MainActor.run {
                            if let info, let price = info.lowestPrice {
                                overlayPriceText = "\(info.title): " + String(format: "$%.2f", price)
                            } else if let info {
                                overlayPriceText = "\(info.title): price unavailable"
                            } else {
                                overlayPriceText = "No product data"
                            }
                        }
                    }
                }
            }
        }
    }

    nonisolated private func detectBarcodeRectsAndPayload(in cgImage: CGImage) -> (boxes: [CGRect], payload: String?) {
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .left, .down]
        for orientation in orientations {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.ean13, .ean8, .upce, .code128, .code39, .qr]
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            try? handler.perform([request])
            if let observations = request.results, !observations.isEmpty {
                let boxes = observations.map { $0.boundingBox }
                let payload = observations.compactMap { $0.payloadStringValue }.first
                return (boxes, payload)
            }
        }
        return ([], nil)
    }

    private var debugInfoOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(frameResolution, systemImage: "camera.viewfinder")
            Label(String(format: "%.1f fps", frameFPS), systemImage: "waveform.path")
        }
        .font(.caption2.weight(.semibold))
        .padding(10)
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .foregroundColor(.white)
        .padding([.top, .leading], 12)
    }

    private var barcodeOverlay: some View {
        GeometryReader { proxy in
            ForEach(Array(barcodeBoxes.enumerated()), id: \.offset) { _, box in
                let rect = convertNormalizedRect(box, in: proxy.size)
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.yellow.opacity(0.9), lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
            }
            if let first = barcodeBoxes.first, let text = overlayPriceText, !text.isEmpty {
                let rect = convertNormalizedRect(first, in: proxy.size)
                Text(text)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.yellow.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 1)
                    .frame(width: rect.width, alignment: .leading)
                    .position(x: rect.midX, y: max(rect.minY - 12, 12))
            }
        }
        .allowsHitTesting(false)
    }

    private func convertNormalizedRect(_ rect: CGRect, in size: CGSize) -> CGRect {
        let x = rect.origin.x * size.width
        // Vision's origin is bottom-left; flip to top-left for SwiftUI coords.
        let y = (1 - rect.origin.y - rect.height) * size.height
        return CGRect(x: x, y: y, width: rect.width * size.width, height: rect.height * size.height)
    }

}
