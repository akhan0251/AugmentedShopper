import SwiftUI
import Vision
import Combine
@preconcurrency import AVFoundation
import MWDATCore
import UIKit
import CoreImage
import UniformTypeIdentifiers
import PhotosUI
import ImageIO

struct ContentView: View {
    @State private var scannedCode: String = ""
    @State private var product: ProductInfo?
    @State private var scanMessage: String? = nil
    @State private var streamingError: String?
    @State private var registrationError: String?
    @State private var activeSheet: ActiveSheet?
    @State private var isGlassesScanActive = false
    @State private var scanTimeoutTask: Task<Void, Never>? = nil
    @State private var savedSampleCount = 0
    @State private var latestFrame: UIImage?
    @State private var streamingStatusText = "Idle"
    @State private var showDebugPreview = false
    @State private var isFrameScanInProgress = false
    @State private var codeFileURL: URL?
    @State private var isProcessingGlassesFrame = false
    @State private var pickedPhotoItem: PhotosPickerItem?
    @State private var lookupTask: Task<Void, Never>?
    @State private var stillCaptureTriggered = false
    @State private var isPhotoPickerPresented = false
    @State private var photoScanTask: Task<Void, Never>?
    @State private var useLiveFallback = false
    @State private var isStartingDebugPreview = false

    private let maxPhotoScanDimension: CGFloat = 2000
    private let barcodeDetectionQueue = DispatchQueue(
        label: "com.raybanpricescanner.barcodeDetection",
        qos: .userInitiated
    )

    @StateObject private var wearablesBridge = WearablesBridge.shared

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.07, green: 0.08, blue: 0.16), Color(red: 0.07, green: 0.28, blue: 0.38)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        header
                        statusCard
                        actionButtons
                        debugPreview
                        connectionControls
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Ray-Ban Price Scanner")
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert("Glasses Error", isPresented: Binding(
            get: { streamingError != nil },
            set: { if !$0 { streamingError = nil } }
        )) {
            Button("OK", role: .cancel) {
                streamingError = nil
            }
        } message: {
            Text(streamingError ?? "")
        }
        .alert("Connect Glasses", isPresented: Binding(
            get: { registrationError != nil },
            set: { if !$0 { registrationError = nil } }
        )) {
            Button("OK", role: .cancel) {
                registrationError = nil
            }
        } message: {
            Text(registrationError ?? "")
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .phoneScanner:
                QRScannerView { code in
                    handleCodeDetected(code)
                    activeSheet = nil
                }
            case .registration:
                RegistrationView(viewModel: wearablesBridge.wearablesViewModel)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didDetectCode)) { notification in
            if let code = notification.object as? String {
                Task { handleCodeDetected(code) }
            }
        }
        .onReceive(wearablesBridge.frameSubject.receive(on: RunLoop.main)) { cgImage in
            print("📸 Got frame from glasses: \(cgImage.width)x\(cgImage.height)")
            if isGlassesScanActive {
                if !stillCaptureTriggered {
                    stillCaptureTriggered = true
                    Task {
                        print("🎯 First frame received, triggering still capture.")
                        await wearablesBridge.streamSessionViewModel.captureHighQualityFrame()
                    }
                } else if useLiveFallback {
                    detectBarcodeFromGlasses(in: cgImage)
                }
            }
            latestFrame = UIImage(cgImage: cgImage)
        }
        .onReceive(wearablesBridge.streamSessionViewModel.$streamingStatus) { status in
            streamingStatusText = {
                switch status {
                case .streaming: return "Streaming"
                case .waiting: return "Waiting"
                case .stopped: return "Stopped"
                }
            }()
        }
        .onReceive(wearablesBridge.streamSessionViewModel.$errorMessage) { message in
            guard wearablesBridge.streamSessionViewModel.showError, !message.isEmpty else { return }
            streamingError = message
            scanMessage = message
        }
        .onReceive(wearablesBridge.streamSessionViewModel.$capturedPhoto) { photo in
            guard isGlassesScanActive, let photo else { return }
            // Prefer a still photo for higher quality detection.
            Task { @MainActor in
                latestFrame = photo
                withAnimation {
                    showDebugPreview = true
                }
            }
            scanCapturedPhoto(photo)
        }
        .onReceive(wearablesBridge.wearablesViewModel.$registrationState) { state in
            print("ℹ️ registrationState updated: \(state)")
        }
        .onReceive(wearablesBridge.wearablesViewModel.$errorMessage) { message in
            guard wearablesBridge.wearablesViewModel.showError, !message.isEmpty else { return }
            registrationError = message
            scanMessage = message
        }
        .onChange(of: pickedPhotoItem) { _, newItem in
            guard let item = newItem else { return }
            Task { @MainActor in
                await loadAndScanPhoto(item: item)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.white.opacity(0.12))
                        .frame(width: 54, height: 54)

                    Image(systemName: "barcode.viewfinder")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Ray-Ban Lens Lab")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Scan glasses barcodes with phone or Meta glasses.")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(2)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                statusPill(color: isGlassesScanActive ? .green : .blue, text: isGlassesScanActive ? "Live" : "Idle")
                statusPill(color: .white.opacity(0.3), text: scannedCode.isEmpty ? "Awaiting barcode" : "Last code \(scannedCode)")
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scan Status")
                    .font(.headline)
                Spacer()
                Image(systemName: "waveform.path.ecg")
                    .foregroundColor(.blue.opacity(0.7))
            }
            .foregroundColor(.white)

            if let product = product {
                VStack(alignment: .leading, spacing: 10) {
                    Text(product.title)
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.white)

                    if let price = product.lowestPrice {
                        Text(String(format: "$%.2f", price))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor(.green)
                    } else {
                        Text("Price not available")
                            .foregroundColor(.white.opacity(0.7))
                    }

                    if let merchant = product.merchant {
                        Text("Merchant: \(merchant)")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.8))
                    }

                    if let url = product.purchaseURL {
                        Link("Purchase link", destination: url)
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.blue)
                    }

                    Text("Code: \(scannedCode)")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.7))
                }
            } else {
                Text(currentStatusMessage)
                    .foregroundColor(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(18)
        .background(.thinMaterial)
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var debugPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.orange.opacity(0.4), Color.red.opacity(0.5)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 42, height: 42)
                    Image(systemName: "livephoto.play")
                        .foregroundColor(.white)
                        .font(.system(size: 18, weight: .semibold))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Debug Live Feed")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Peek at the glasses stream and run quick checks without opening the full viewer.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                statusPill(color: streamingStatusColor, text: streamingStatusText)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showDebugPreview.toggle()
                    }
                } label: {
                    Label(showDebugPreview ? "Hide feed" : "Show feed", systemImage: showDebugPreview ? "eye.slash.fill" : "eye.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.mint.opacity(0.9))

                Button {
                    Task {
                        scanMessage = "Starting live preview…"
                        await startPreviewIfNeeded()
                        withAnimation(.easeInOut) { showDebugPreview = true }
                    }
                } label: {
                    Label("Start preview", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.blue.opacity(0.9))

                Button {
                    scanLatestFrame()
                } label: {
                    Label(isFrameScanInProgress ? "Scanning…" : "Scan frame", systemImage: "viewfinder.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.yellow)
                .disabled(isFrameScanInProgress || currentPreviewFrame == nil)

                Button(role: .destructive) {
                    wearablesBridge.stopStreaming()
                    streamingStatusText = "Stopped"
                } label: {
                    Label("Stop stream", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)

            Divider()
                .overlay(Color.white.opacity(0.12))

            if showDebugPreview {
                if let frame = currentPreviewFrame {
                    VStack(alignment: .leading, spacing: 12) {
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: frame)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(.white.opacity(0.22), lineWidth: 1)
                                )
                                .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 8)

                            HStack(spacing: 8) {
                                statusPill(color: .red, text: "Live tap")
                                statusPill(color: .white.opacity(0.2), text: "\(Int(frame.size.width))x\(Int(frame.size.height))")
                            }
                            .padding(10)
                        }

                        HStack(spacing: 10) {
                            ShareLink(item: TransferableImage(image: frame), preview: SharePreview("Glasses Frame", image: Image(uiImage: frame))) {
                                Image(systemName: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderedProminent)

                            Button {
                                copyFrameBase64(frame)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.bordered)

                            Button {
                                scanLatestFrame()
                            } label: {
                                Image(systemName: "arrow.clockwise.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.bordered)
                            .tint(.yellow.opacity(0.9))
                            .disabled(isFrameScanInProgress)
                        }
                        .controlSize(.small)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No frames yet.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.white)
                        Text("Start the preview to pull a fresh frame from the glasses for debugging.")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            } else {
                Text("Keep this collapsed during demos. When you need it, open the feed to verify streaming and barcode detection.")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.10),
                            Color.white.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            NavigationLink {
                LiveStreamView()
            } label: {
                FancyLink(
                    title: "Live Stream Viewer",
                    subtitle: "Glasses & Screenshots",
                    tint: .mint,
                    systemImage: "livephoto.play"
                )
            }

            FancyButton(title: "Scan with iPhone Camera", subtitle: "Fast, uses native camera", tint: .cyan, systemImage: "iphone") {
                activeSheet = .phoneScanner
            }

            FancyButton(title: "Scan with Meta Glasses", subtitle: "Hands-free bar code scanning", tint: .orange, systemImage: "eyeglasses") {
                startGlassesScan()
            }

            if let codeFileURL = makeCodeTextFile() {
                ShareLink(item: codeFileURL) {
                    Label("Share code as text file", systemImage: "square.and.arrow.up.on.square")
                }
                .buttonStyle(.borderedProminent)
            }

            Button {
                isPhotoPickerPresented = true
            } label: {
                Label("Pick Photo from Library", systemImage: "photo.on.rectangle")
                    .frame(minWidth: 180, maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .sheet(isPresented: $isPhotoPickerPresented) {
                LibraryPhotoPicker { image in
                    handlePickedImage(image)
                }
            }

        }
    }

    private var connectionControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    activeSheet = .registration
                } label: {
                    Label("Register Glasses", systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue.opacity(0.9))

                Button {
                    wearablesBridge.disconnectGlasses()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
    }

    private var currentStatusMessage: String {
        if let scanMessage {
            return scanMessage
        } else if isGlassesScanActive {
            return "Scanning with Meta glasses… hold the barcode steady."
        } else {
            return "No product scanned yet. Choose how you want to scan."
        }
    }

    private var streamingStatusColor: Color {
        switch streamingStatusText.lowercased() {
        case "streaming":
            return .green
        case "waiting":
            return .orange
        default:
            return .white.opacity(0.35)
        }
    }

    private var currentPreviewFrame: UIImage? {
        latestFrame ?? wearablesBridge.streamSessionViewModel.currentVideoFrame
    }

    private func statusPill(color: Color, text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color)
            .foregroundColor(.white)
            .clipShape(Capsule())
    }

    private func startGlassesScan() {
        guard wearablesBridge.wearablesViewModel.registrationState == .registered else {
            registrationError = "Glasses are not connected. Open registration to approve in Meta AI, then return."
            scanMessage = registrationError
            activeSheet = .registration
            return
        }

        print("▶️ Starting glasses scan")
        resetGlassesScanState()
        scanMessage = "Scanning with glasses…"
        product = nil
        scannedCode = ""
        isGlassesScanActive = true
        useLiveFallback = false

        scanTimeoutTask = Task {
            // Allow the camera to start and deliver a few frames.
            try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            await MainActor.run {
                if isGlassesScanActive {
                    stopGlassesScan()
                    scanMessage = "No barcode detected from glasses."
                }
            }
        }

        Task {
            if wearablesBridge.streamSessionViewModel.isSessionActive {
                wearablesBridge.stopStreaming()
                try? await Task.sleep(nanoseconds: 150_000_000) // brief gap to allow restart
            }
            await wearablesBridge.startStreaming()
            // Wait for first frame to trigger a still capture; avoid live-frame detection.
        }
    }

    private func stopGlassesScan() {
        isGlassesScanActive = false
        resetGlassesScanState()
        wearablesBridge.stopStreaming()
    }

    private func detectBarcodeFromGlasses(in cgImage: CGImage) {
        guard !isProcessingGlassesFrame else { return }
        isProcessingGlassesFrame = true

        // Focus on UPC/EAN first for glasses, fall back to common codes.
        let symbologies: [VNBarcodeSymbology] = [
            .ean13,
            .ean8,
            .upce,
            .code128,
            .code93,
            .code39,
            .qr,
            .pdf417
        ]

        let orientations: [CGImagePropertyOrientation] = [
            .right,
            .up,
            .left,
            .down,
            .rightMirrored,
            .upMirrored,
            .leftMirrored,
            .downMirrored
        ]

        if savedSampleCount < 3 {
            saveSampleFrame(cgImage)
        }

        barcodeDetectionQueue.async {
            let payload = detectPayload(
                in: cgImage,
                symbologies: symbologies,
                orientations: orientations
            )
            Task { @MainActor in
                self.isProcessingGlassesFrame = false
                if let payload {
                    print("✅ Detected barcode from glasses")
                    self.stopGlassesScan()
                    self.handleCodeDetected(payload, source: .glasses)
                } else {
                    self.scanMessage = "No barcode found in live frame."
                }
            }
        }
    }

    nonisolated private func detectPayload(in cgImage: CGImage,
                               symbologies: [VNBarcodeSymbology]? = nil,
                               orientations: [CGImagePropertyOrientation]? = nil) -> String? {
        let requestedSymbologies = symbologies ?? [
            .ean13, .ean8, .upce, .code128, .code93, .code39, .qr, .pdf417
        ]
        let dirs = orientations ?? [
            .right, .up, .left, .down, .rightMirrored, .upMirrored, .leftMirrored, .downMirrored
        ]

        let primaryCandidates: [VNBarcodeSymbology] = [.ean13, .ean8, .upce, .code128]
        let fallbackCandidates: [VNBarcodeSymbology] = [.code39, .code93, .qr, .pdf417]
        let primary = requestedSymbologies.filter { primaryCandidates.contains($0) }
        let fallback = requestedSymbologies.filter { fallbackCandidates.contains($0) && !primary.contains($0) }
        let primaryOrAll = primary.isEmpty ? requestedSymbologies : primary

        // Try the original + a single upscale before any cropping/filters.
        if let directPayload = quickDetectOnOriginal(
            cgImage,
            symbologies: primaryOrAll,
            orientations: dirs
        ) {
            return directPayload
        }

        // Targeted bottom-band first (where UPC usually is).
        if let bandPayload = detectBottomBand(
            in: cgImage,
            symbologies: primaryOrAll,
            orientations: dirs
        ) {
            return bandPayload
        }

        let variants = barcodeVariants(from: cgImage)

        for orientation in dirs {
            for variant in variants {
                if let payload = performBarcodeDetection(on: variant,
                                                         orientation: orientation,
                                                         symbologies: primaryOrAll) {
                    return payload
                }
            }
        }

        for orientation in dirs {
            for variant in variants {
                if let payload = performBarcodeDetection(on: variant,
                                                         orientation: orientation,
                                                         symbologies: primaryOrAll + fallback) {
                    return payload
                }
            }
        }

        return nil
    }

    nonisolated private func quickDetectOnOriginal(_ cgImage: CGImage,
                                       symbologies: [VNBarcodeSymbology],
                                       orientations: [CGImagePropertyOrientation]) -> String? {
        var variants = [cgImage]
        if let up = upscaleImage(cgImage, maxDimension: 4800) { variants.append(up) }
        if let mono = highContrastMono(cgImage) { variants.append(mono) }
        if let strong = strongMonoThreshold(cgImage) { variants.append(strong) }
        if let upMono = variants.first.flatMap({ highContrastMono($0) }) { variants.append(upMono) }
        if let upStrong = variants.first.flatMap({ strongMonoThreshold($0) }) { variants.append(upStrong) }

        for orientation in orientations {
            for variant in variants {
                if let payload = performBarcodeDetection(on: variant,
                                                         orientation: orientation,
                                                         symbologies: symbologies) {
                    return payload
                }
            }
        }
        return nil
    }

    nonisolated private func detectBottomBand(in cgImage: CGImage,
                                  symbologies: [VNBarcodeSymbology],
                                  orientations: [CGImagePropertyOrientation]) -> String? {
        // Crop a bottom band and aggressively upscale/monochrome it.
        let bandHeights: [CGFloat] = [0.65, 0.55, 0.45, 0.35, 0.25, 0.18]
        let bandWidths: [CGFloat] = [1.0, 0.95, 0.85, 0.75, 0.6]
        var bandVariants: [CGImage] = []

        for h in bandHeights {
            for w in bandWidths {
                if let band = bottomCenterCrop(cgImage, heightFraction: h, widthFraction: w) {
                    bandVariants.append(band)
                    if let up = upscaleImage(band, maxDimension: 3800) { bandVariants.append(up) }
                    if let mono = highContrastMono(band) { bandVariants.append(mono) }
                    if let strong = strongMonoThreshold(band) { bandVariants.append(strong) }
                    if let morph = morphologicalClose(band) { bandVariants.append(morph) }
                }
            }
        }

        for orientation in orientations {
            for variant in bandVariants {
                if let payload = performBarcodeDetection(on: variant,
                                                         orientation: orientation,
                                                         symbologies: symbologies) {
                    return payload
                }
            }
        }
        return nil
    }

    nonisolated private func performBarcodeDetection(on cgImage: CGImage,
                                         orientation: CGImagePropertyOrientation,
                                         symbologies: [VNBarcodeSymbology]) -> String? {
        let revisions = VNDetectBarcodesRequest.supportedRevisions.sorted(by: >)

        for rev in revisions {
            let request = VNDetectBarcodesRequest()
            request.symbologies = symbologies
            request.revision = rev

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            try? handler.perform([request])

            guard let observations = request.results else { continue }
            if let payload = observations.compactMap({ $0.payloadStringValue }).first(where: { !$0.isEmpty }) {
                return payload
            }
        }
        return nil
    }

    nonisolated private func barcodeVariants(from cgImage: CGImage) -> [CGImage] {
        var results: [CGImage] = []

        if let strong = strongMonoThreshold(cgImage) { results.append(strong) }
        if let bin = highContrastMono(cgImage) { results.append(bin) }
        if let morph = morphologicalClose(cgImage) { results.append(morph) }
        if let dark = gammaAdjust(cgImage, power: 0.85) { results.append(dark) }
        if let bright = gammaAdjust(cgImage, power: 1.2) { results.append(bright) }

        results.append(cgImage)
        if let enhanced = enhanceImage(cgImage) { results.append(enhanced) }
        if let upscaled = upscaleImage(cgImage, maxDimension: 3200) { results.append(upscaled) }

        for fraction in [0.85, 0.7, 0.55, 0.4] {
            if let crop = centerCrop(cgImage, fraction: fraction) {
                results.append(crop)
                if let upCrop = upscaleImage(crop, maxDimension: 2600) {
                    results.append(upCrop)
                }
            }
        }
        for heightFraction in [0.55, 0.4, 0.3, 0.2] {
            if let band = bottomCenterCrop(cgImage, heightFraction: heightFraction, widthFraction: 0.8) {
                results.append(band)
                if let upBand = upscaleImage(band, maxDimension: 2600) {
                    results.append(upBand)
                }
            }
        }

        return results
    }

    nonisolated private func enhanceImage(_ cgImage: CGImage) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
        let contrasted = ciImage
            .applyingFilter("CIColorControls", parameters: ["inputContrast": 1.2])
            .applyingFilter("CIUnsharpMask", parameters: ["inputIntensity": 0.7, "inputRadius": 1.0])

        let context = CIContext(options: nil)
        return context.createCGImage(contrasted, from: contrasted.extent)
    }

    nonisolated private func upscaleImage(_ cgImage: CGImage, maxDimension: CGFloat = 2000, maxScale: CGFloat = 2.5) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let scale = min(maxDimension / max(size.width, size.height), maxScale)
        guard scale > 1 else { return nil }
        let scaled = ciImage
            .applyingFilter("CILanczosScaleTransform", parameters: [
                "inputScale": scale,
                "inputAspectRatio": size.width / size.height
            ])
        let context = CIContext(options: nil)
        return context.createCGImage(scaled, from: scaled.extent)
    }

    nonisolated private func centerCrop(_ cgImage: CGImage, fraction: CGFloat) -> CGImage? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let cropW = width * fraction
        let cropH = height * fraction
        let rect = CGRect(
            x: (width - cropW) / 2,
            y: (height - cropH) / 2,
            width: cropW,
            height: cropH
        )
        return cgImage.cropping(to: rect)
    }

    nonisolated private func bottomCenterCrop(_ cgImage: CGImage, heightFraction: CGFloat, widthFraction: CGFloat) -> CGImage? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let cropH = height * heightFraction
        let cropW = width * widthFraction
        let rect = CGRect(
            x: (width - cropW) / 2,
            y: height - cropH,
            width: cropW,
            height: cropH
        )
        return cgImage.cropping(to: rect)
    }

    nonisolated private func highContrastMono(_ cgImage: CGImage) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
        let mono = ciImage
            .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0.0, "inputContrast": 1.6])
            .applyingFilter("CIUnsharpMask", parameters: ["inputIntensity": 0.8, "inputRadius": 1.2])
        let context = CIContext(options: nil)
        return context.createCGImage(mono, from: mono.extent)
    }

    nonisolated private func strongMonoThreshold(_ cgImage: CGImage, threshold: CGFloat = 0.55) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
        let gray = ciImage
            .applyingFilter("CIColorControls", parameters: [
                "inputSaturation": 0.0,
                "inputContrast": 2.4,
                "inputBrightness": 0.05
            ])
            .applyingFilter("CIExposureAdjust", parameters: ["inputEV": 0.3])

        let clamp = gray.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: threshold, y: threshold, z: threshold, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ])

        let context = CIContext(options: nil)
        return context.createCGImage(clamp, from: clamp.extent)
    }

    nonisolated private func gammaAdjust(_ cgImage: CGImage, power: CGFloat) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
        let adjusted = ciImage.applyingFilter("CIGammaAdjust", parameters: ["inputPower": power])
        let context = CIContext(options: nil)
        return context.createCGImage(adjusted, from: adjusted.extent)
    }

    nonisolated private func sharpenImage(_ cgImage: CGImage, radius: CGFloat = 1.0, intensity: CGFloat = 0.9) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
        let sharpened = ciImage.applyingFilter("CIUnsharpMask", parameters: [
            "inputRadius": radius,
            "inputIntensity": intensity
        ])
        let context = CIContext(options: nil)
        return context.createCGImage(sharpened, from: sharpened.extent)
    }

    nonisolated private func detectPayloadLowResPhoto(in cgImage: CGImage) -> String? {
        // Extra-aggressive path for low-res photos, but process variants streaming to reduce memory.
        let syms: [VNBarcodeSymbology] = [.ean13, .ean8, .upce, .code128, .code39, .code93]
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .left, .down, .upMirrored, .rightMirrored, .leftMirrored, .downMirrored]

        func detectVariants(_ images: [CGImage]) -> String? {
            for image in images {
                for orientation in orientations {
                    if let payload = performBarcodeDetection(on: image, orientation: orientation, symbologies: syms) {
                        return payload
                    }
                }
            }
            return nil
        }

        func variants(from image: CGImage) -> [CGImage] {
            var arr: [CGImage] = [image]
            if let sharp = sharpenImage(image, radius: 1.2, intensity: 1.0) { arr.append(sharp) }
            if let mono = highContrastMono(image) { arr.append(mono) }
            if let strong = strongMonoThreshold(image, threshold: 0.58) { arr.append(strong) }
            if let morph = morphologicalClose(image, radius: 3.2) { arr.append(morph) }
            return arr
        }

        let seeds: [CGImage] = {
            var s: [CGImage] = [cgImage]
            if let up = upscaleImage(cgImage, maxDimension: maxPhotoScanDimension, maxScale: 3.0) { s.append(up) }
            return s
        }()

        let bandHeights: [CGFloat] = [0.45, 0.36, 0.28, 0.22]
        let bandWidths: [CGFloat] = [1.0, 0.92, 0.82]

        for seed in seeds {
            if Task.isCancelled { return nil }
            // Seed variants
            if let payload = detectVariants(variants(from: seed)) { return payload }

            // Band variants per seed to keep memory low
            for h in bandHeights {
                for w in bandWidths {
                    if Task.isCancelled { return nil }
                    guard let band = bottomCenterCrop(seed, heightFraction: h, widthFraction: w) else { continue }
                    if let payload = detectVariants(variants(from: band)) { return payload }
                    if let upBand = upscaleImage(band, maxDimension: maxPhotoScanDimension, maxScale: 3.0) {
                        if Task.isCancelled { return nil }
                        if let payload = detectVariants(variants(from: upBand)) { return payload }
                    }
                }
            }
        }
        return nil
    }

    nonisolated private func detectPayloadFast(in cgImage: CGImage) -> String? {
        // Fast path for manual “Scan Current Frame”: fewer variants, UPC/EAN/128 only, but with added contrast/sharpen for low-res frames.
        let syms: [VNBarcodeSymbology] = [.ean13, .ean8, .upce, .code128]
        let orientations: [CGImagePropertyOrientation] = [.right, .up, .left, .down]

        // Bottom band variants (likely location).
        var variants: [CGImage] = []
        let fastHeights: [CGFloat] = [0.32, 0.28, 0.24]
        let fastWidths: [CGFloat] = [1.0, 0.9]
        for h in fastHeights {
            for w in fastWidths {
                if Task.isCancelled { return nil }
                if let band = bottomCenterCrop(cgImage, heightFraction: h, widthFraction: w) {
                    variants.append(band)
                    if let up = upscaleImage(band, maxDimension: 4000) { variants.append(up) }
                    if let mono = highContrastMono(band) { variants.append(mono) }
                    if let strong = strongMonoThreshold(band) { variants.append(strong) }
                    if let sharp = sharpenImage(band, radius: 1.1, intensity: 1.0) { variants.append(sharp) }
                    if let morph = morphologicalClose(band) { variants.append(morph) }
                }
            }
        }

        // Center crop + original.
        if let crop = centerCrop(cgImage, fraction: 0.65) { variants.append(crop) }
        variants.append(cgImage)
        if let mono = highContrastMono(cgImage) { variants.append(mono) }
        if let strong = strongMonoThreshold(cgImage) { variants.append(strong) }
        if let sharp = sharpenImage(cgImage, radius: 1.1, intensity: 1.0) { variants.append(sharp) }
        if let up = upscaleImage(cgImage, maxDimension: 4200, maxScale: 3.0) { variants.append(up) }

        for orientation in orientations {
            for variant in variants {
                if Task.isCancelled { return nil }
                if let payload = performBarcodeDetection(on: variant, orientation: orientation, symbologies: syms) {
                    return payload
                }
            }
        }
        return nil
    }

    nonisolated private func equalizedMono(_ cgImage: CGImage) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
        let mono = ciImage.applyingFilter("CIPhotoEffectMono")
        let histo = mono.applyingFilter("CIAreaHistogram", parameters: [
            "inputExtent": CIVector(x: mono.extent.origin.x, y: mono.extent.origin.y, z: mono.extent.size.width, w: mono.extent.size.height),
            "inputCount": 256
        ])
        let equalized = histo.applyingFilter("CIHistogramDisplayFilter", parameters: [
            "inputHeight": 256
        ])
        let context = CIContext(options: nil)
        return context.createCGImage(equalized, from: equalized.extent)
    }

    nonisolated private func morphologicalClose(_ cgImage: CGImage, radius: CGFloat = 2.5) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
        let closed = ciImage
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": radius])
            .applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": radius])
        let context = CIContext(options: nil)
        return context.createCGImage(closed, from: closed.extent)
    }

    private func startPreviewIfNeeded() async {
        if isStartingDebugPreview {
            return
        }

        if wearablesBridge.streamSessionViewModel.isStreaming {
            print("ℹ️ Stream already running for debug preview (reg state: \(wearablesBridge.wearablesViewModel.registrationState))")
            return
        }

        if wearablesBridge.wearablesViewModel.registrationState != .registered {
            scanMessage = "Glasses not connected. Open registration."
            activeSheet = .registration
            return
        }

        isStartingDebugPreview = true
        scanMessage = "Starting debug preview…"
        await wearablesBridge.startFreshDebugStream()
        isStartingDebugPreview = false
        print("ℹ️ Attempted to start streaming for debug preview (reg state: \(wearablesBridge.wearablesViewModel.registrationState))")
    }

    private func scanLatestFrame() {
        guard !isFrameScanInProgress else { return }
        guard let frame = latestFrame ?? wearablesBridge.streamSessionViewModel.currentVideoFrame,
              let cgImage = frame.cgImage else {
            scanMessage = "No frame available to scan."
            return
        }
        isFrameScanInProgress = true
        scanMessage = "Scanning current frame…"
        Task.detached(priority: .userInitiated) {
            let payload = detectPayloadFast(in: cgImage)
            await MainActor.run {
                if let payload {
                    handleCodeDetected(payload)
                    scanMessage = "Found code: \(payload)"
                } else {
                    scanMessage = "No barcode found in current frame."
                }
                isFrameScanInProgress = false
            }
        }
    }

    nonisolated private func downscaleImageData(_ data: Data, maxDimension: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else { return nil }
        let thumbOptions: [NSString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgThumb)
    }

    @MainActor
    private func loadAndScanPhoto(item: PhotosPickerItem) async {
        pickedPhotoItem = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                scanMessage = "Could not load that photo."
                return
            }

            // Downscale off the main actor to keep memory pressure low.
            var processedImage: UIImage? = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    downscaleImageData(data, maxDimension: maxPhotoScanDimension) ?? UIImage(data: data)
                }
            }.value

            // Fallback to a smaller decode if memory was tight.
            if processedImage == nil {
                processedImage = await Task.detached(priority: .utility) {
                    autoreleasepool {
                        downscaleImageData(data, maxDimension: 1800)
                    }
                }.value
            }

            guard let image = processedImage else {
                scanMessage = "Could not load that photo."
                return
            }

            latestFrame = image
            scanMessage = "Photo loaded. Scanning…"
            scanPhoto(image)
        } catch {
            scanMessage = "Photo load failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func handlePickedImage(_ image: UIImage) {
        latestFrame = image
        scanMessage = "Photo loaded. Scanning…"
        scanPhoto(image)
    }

    private func scanPhoto(_ image: UIImage) {
        photoScanTask?.cancel()
        guard !isFrameScanInProgress else { return }
        guard let cgImage = image.cgImage else {
            scanMessage = "Could not read photo."
            return
        }
        isFrameScanInProgress = true
        scanMessage = "Scanning photo…"

        let task = Task.detached(priority: .userInitiated) {
            let payload = detectPayloadLowResPhoto(in: cgImage) ?? detectPayloadFast(in: cgImage)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                print("🖼️ Photo scan finished. Payload: \(payload ?? "nil")")
                if let payload {
                    handleCodeDetected(payload)
                    scanMessage = "Found code: \(payload)"
                } else {
                    scanMessage = "No barcode found in photo."
                }
                isFrameScanInProgress = false
            }
        }
        photoScanTask = task

        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !task.isCancelled else { return }
            task.cancel()
            await MainActor.run {
                scanMessage = "Photo scan timed out."
                isFrameScanInProgress = false
            }
        }
    }

    private func scanCapturedPhoto(_ image: UIImage) {
        photoScanTask?.cancel()
        guard !isFrameScanInProgress else { return }
        guard let cgImage = image.cgImage else { return }
        isFrameScanInProgress = true
        scanMessage = "Scanning captured photo…"
        print("📸 Captured photo received from glasses. Starting scan.")

        let task = Task.detached(priority: .userInitiated) {
            let payload = detectPayload(in: cgImage) ?? detectPayloadFast(in: cgImage)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                print("📸 Captured photo scan finished. Payload: \(payload ?? "nil")")
                if let payload {
                    handleCodeDetected(payload, source: .glasses)
                    scanMessage = "Found code: \(payload)"
                    stopGlassesScan()
                } else {
                    scanMessage = "No barcode found in captured photo. Trying live frames…"
                    useLiveFallback = true
                }
                isFrameScanInProgress = false
            }
        }
        photoScanTask = task

        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !task.isCancelled else { return }
            task.cancel()
            await MainActor.run {
                scanMessage = "Captured photo scan timed out. Trying live frames…"
                isFrameScanInProgress = false
                useLiveFallback = true
            }
        }
    }

    private func resetGlassesScanState() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        savedSampleCount = 0
        isProcessingGlassesFrame = false
        stillCaptureTriggered = false
        useLiveFallback = false
    }

    private func copyFrameBase64(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        UIPasteboard.general.string = data.base64EncodedString()
        print("📋 Copied frame base64 to pasteboard.")
        scanMessage = "Copied frame base64 to pasteboard."
    }

    private func saveSampleFrame(_ cgImage: CGImage) {
        let image = UIImage(cgImage: cgImage)
        guard let data = image.jpegData(compressionQuality: 0.95),
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

        let filename = "glasses_frame_\(Int(Date().timeIntervalSince1970)).jpg"
        let url = docs.appendingPathComponent(filename)
        do {
            try data.write(to: url)
            savedSampleCount += 1
            print("💾 Saved glasses frame sample to \(url.path)")
        } catch {
            print("⚠️ Failed to save sample frame: \(error.localizedDescription)")
        }
    }

    private func makeCodeTextFile() -> URL? {
        guard !scannedCode.isEmpty else { return nil }
        let lines: [String] = [
            "Barcode: \(scannedCode)",
            product?.title ?? "Product: unknown",
            product?.lowestPrice.map { String(format: "Price: $%.2f", $0) } ?? "Price: unavailable",
            product?.merchant.map { "Merchant: \($0)" } ?? "Merchant: unknown",
            product?.purchaseURL != nil ? "Link: \(product!.purchaseURL!.absoluteString)" : "Link: none"
        ]
        let content = lines.joined(separator: "\n")
        guard let data = content.data(using: .utf8) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("barcode.txt")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("⚠️ Failed to write code file: \(error.localizedDescription)")
            return nil
        }
    }

    private func handleCodeDetected(_ code: String, source: ScanSource = .generic) {
        lookupTask?.cancel()
        scannedCode = code
        product = nil
        let foundMessage = source == .glasses
        ? "Found code: \(code). Saving to Files and looking up…"
        : "Found code: \(code). Looking up…"
        scanMessage = foundMessage
        if source == .glasses {
            persistGlassesBarcode(code)
        }
        print("🔍 Detected code \(code). Starting lookup.")

        let currentCode = code
        lookupTask = Task {
            do {
                let result = try await ProductLookupService.shared.lookup(upc: currentCode)
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    if let result {
                        product = result
                        scanMessage = statusLine(for: result)
                        speakForProduct(result)
                        print("✅ Lookup success for \(currentCode): \(statusLine(for: result))")
                    } else {
                        Task {
                            let diag = await ProductLookupService.shared.debugLookup(upc: currentCode)
                            await MainActor.run {
                                scanMessage = "Detected \(currentCode), but no product data was returned. \(diag)"
                                SpeechService.shared.speak("I found the code but no product info was available.")
                                print("⚠️ Lookup returned no data for \(currentCode). \(diag)")
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    scanMessage = "Detected \(currentCode), but lookup failed: \(error.localizedDescription)"
                    SpeechService.shared.speak("I found the code but the lookup failed.")
                    print("❌ Lookup failed for \(currentCode): \(error.localizedDescription)")
                }
            }
        }
    }

    private func persistGlassesBarcode(_ code: String) {
        Task.detached(priority: .background) {
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let filename = "glasses_barcode_\(Int(Date().timeIntervalSince1970)).txt"
            let url = docs.appendingPathComponent(filename)
            do {
                try "Barcode: \(code)".write(to: url, atomically: true, encoding: .utf8)
                print("💾 Saved glasses barcode to \(url.path)")
            } catch {
                print("⚠️ Failed to save glasses barcode: \(error.localizedDescription)")
            }
        }
    }

    private func statusLine(for product: ProductInfo) -> String {
        if let price = product.lowestPrice {
            return "\(product.title): \(String(format: "$%.2f", price))"
        } else {
            return "\(product.title): price unavailable"
        }
    }

    private func speakForProduct(_ product: ProductInfo) {
        if let price = product.lowestPrice {
            let speech = "\(product.title) is \(String(format: "$%.2f", price))."
            SpeechService.shared.speak(speech)
        } else {
            let speech = "I found \(product.title), but I couldn't get a price."
            SpeechService.shared.speak(speech)
        }
    }
}

// UIKit picker to avoid PhotosPicker layout warnings
struct LibraryPhotoPicker: UIViewControllerRepresentable {
    var onImagePicked: (UIImage) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onImagePicked: (UIImage) -> Void

        init(onImagePicked: @escaping (UIImage) -> Void) {
            self.onImagePicked = onImagePicked
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else { return }
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    if let image = object as? UIImage {
                        DispatchQueue.main.async {
                            self.onImagePicked(image)
                        }
                    }
                }
            }
        }
    }
}

enum ActiveSheet: Identifiable {
    case phoneScanner
    case registration

    var id: Int {
        switch self {
        case .phoneScanner: return 0
        case .registration: return 1
        }
    }
}

private enum ScanSource {
    case generic
    case glasses
}

struct FancyButton: View {
    var title: String
    var subtitle: String
    var tint: Color
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: systemImage)
                        .foregroundColor(tint)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.7))
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct FancyLink: View {
    var title: String
    var subtitle: String
    var tint: Color
    var systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: systemImage)
                    .foregroundColor(tint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.7))
            }
            Spacer()
            Image(systemName: "arrow.right")
                .foregroundColor(.white.opacity(0.8))
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
