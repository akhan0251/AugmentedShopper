import SwiftUI
import AVFoundation
import Vision
import CoreImage

struct QRScannerView: UIViewRepresentable {
    var onDetect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDetect: onDetect)
    }

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView(frame: .zero)
        context.coordinator.setupSession(in: view)
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        context.coordinator.updatePreviewFrame(in: uiView)
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
        private let onDetect: (String) -> Void
        private let session = AVCaptureSession()
        private let visionQueue = DispatchQueue(label: "com.raybanpricescanner.vision", qos: .userInitiated)
        private let ciContext = CIContext()
        private weak var previewLayer: AVCaptureVideoPreviewLayer?
        private var hasDetected = false
        private var lastVisionScan = Date.distantPast
        private let visionThrottle: TimeInterval = 0.2

        init(onDetect: @escaping (String) -> Void) {
            self.onDetect = onDetect
            super.init()
        }

        func setupSession(in view: PreviewContainerView) {
            // Request camera access if needed, then start session
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                startSession(in: view)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        if granted {
                            self.startSession(in: view)
                        } else {
                            print("⚠️ Camera access denied")
                        }
                    }
                }
            default:
                print("⚠️ Camera access not available")
            }
        }

        private func startSession(in view: PreviewContainerView) {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                print("⚠️ Could not create camera input")
                return
            }
            hasDetected = false

            session.beginConfiguration()
            if session.canSetSessionPreset(.photo) {
                session.sessionPreset = .photo
            } else {
                session.sessionPreset = .high
            }

            let metadataOutput = AVCaptureMetadataOutput()
            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: visionQueue)
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]

            if session.canAddInput(input) {
                session.addInput(input)
            }
            if session.canAddOutput(metadataOutput) {
                session.addOutput(metadataOutput)
            }
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }

            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            let desiredTypes: [AVMetadataObject.ObjectType] = [.qr, .ean8, .ean13, .upce, .code128, .code39, .code93]
            let supportedTypes = metadataOutput.availableMetadataObjectTypes.filter { desiredTypes.contains($0) }
            metadataOutput.metadataObjectTypes = supportedTypes.isEmpty ? metadataOutput.availableMetadataObjectTypes : supportedTypes
            // Use full frame to maximize hits regardless of phone position.
            metadataOutput.rectOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)

            if let connection = videoOutput.connection(with: .video) {
                if #available(iOS 17, *) {
                    if connection.isVideoRotationAngleSupported(90) {
                        connection.videoRotationAngle = 90
                    }
                } else if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .standard
                }
            }

            session.commitConfiguration()

            configureDevice(device)

            addPreviewLayer(to: view)
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }

        private func addPreviewLayer(to view: PreviewContainerView) {
            let previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = view.bounds
            view.layer.addSublayer(previewLayer)
            view.previewLayer = previewLayer
            self.previewLayer = previewLayer
        }

        private func configureDevice(_ device: AVCaptureDevice) {
            do {
                try device.lockForConfiguration()
                if device.isAutoFocusRangeRestrictionSupported {
                    device.autoFocusRangeRestriction = .near
                }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                if device.isSmoothAutoFocusSupported {
                    device.isSmoothAutoFocusEnabled = true
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                if device.isLowLightBoostSupported {
                    device.automaticallyEnablesLowLightBoostWhenAvailable = true
                }

                let targetZoom: CGFloat = 1.4
                let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 3.0)
                if maxZoom >= targetZoom {
                    device.videoZoomFactor = targetZoom
                }
                device.unlockForConfiguration()
            } catch {
                print("⚠️ Could not lock device for configuration: \(error.localizedDescription)")
            }
        }

        func updatePreviewFrame(in view: PreviewContainerView) {
            previewLayer?.frame = view.bounds
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = obj.stringValue else { return }
            handleDetection(value)
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard !hasDetected,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            let now = Date()
            guard now.timeIntervalSince(lastVisionScan) > visionThrottle else { return }
            lastVisionScan = now

            autoreleasepool {
                if let value = detectPayload(in: pixelBuffer) {
                    DispatchQueue.main.async {
                        self.handleDetection(value)
                    }
                }
            }
        }

        private func handleDetection(_ value: String) {
            guard !hasDetected else { return }
            hasDetected = true
            // Stop the session off the main thread to avoid UI hitches, then notify on the main queue.
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.stopRunning()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .didDetectCode, object: value)
                    self.onDetect(value)
                }
            }
        }

        private func detectPayload(in pixelBuffer: CVPixelBuffer) -> String? {
            if let direct = try? performVisionRequest(on: pixelBuffer, orientation: .right) {
                return direct
            }
            if let rotated = try? performVisionRequest(on: pixelBuffer, orientation: .up) {
                return rotated
            }

            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }

            if let value = detectPayload(in: cgImage) {
                return value
            }

            if let boosted = boostedImage(from: cgImage) {
                return detectPayload(in: boosted)
            }

            if let digits = recognizeDigits(in: cgImage) {
                return digits
            }

            return nil
        }

        private func detectPayload(in cgImage: CGImage) -> String? {
            let orientations: [CGImagePropertyOrientation] = [.right, .up, .left, .down]

            for orientation in orientations {
                let request = makeBarcodeRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
                try? handler.perform([request])

                if let observations = request.results,
                   let payload = observations
                    .compactMap(\.payloadStringValue)
                    .first(where: { !$0.isEmpty }) {
                    return payload
                }
            }

            // Targeted bottom-band and boosted variants for small/blurred barcodes.
            let bandHeights: [CGFloat] = [0.55, 0.45, 0.35, 0.25]
            let bandWidths: [CGFloat] = [1.0, 0.9, 0.78]
            var variants: [CGImage] = []

            for h in bandHeights {
                for w in bandWidths {
                    if let band = bottomCenterCrop(cgImage, heightFraction: h, widthFraction: w) {
                        variants.append(band)
                        if let up = upscaleImage(band, maxDimension: 3600) { variants.append(up) }
                        if let mono = highContrastMono(band) { variants.append(mono) }
                        if let strong = strongMonoThreshold(band) { variants.append(strong) }
                        if let strongLow = strongMonoThreshold(band, threshold: 0.5) { variants.append(strongLow) }
                        if let strongHigh = strongMonoThreshold(band, threshold: 0.65) { variants.append(strongHigh) }
                        if let morph = morphologicalClose(band) { variants.append(morph) }
                        if let sharp = sharpenImage(band) { variants.append(sharp) }
                        if let dark = gammaAdjust(band, power: 0.9) { variants.append(dark) }
                        if let bright = gammaAdjust(band, power: 1.1) { variants.append(bright) }
                    }
                }
            }

            for orientation in orientations {
                for variant in variants {
                    let request = makeBarcodeRequest()
                    let handler = VNImageRequestHandler(cgImage: variant, orientation: orientation)
                    try? handler.perform([request])

                    if let observations = request.results,
                       let payload = observations
                        .compactMap(\.payloadStringValue)
                        .first(where: { !$0.isEmpty }) {
                        return payload
                    }
                }
            }

            return nil
        }

        /// OCR fallback to recover printed digits when bars are too blurred.
        private func recognizeDigits(in cgImage: CGImage) -> String? {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.018
            request.recognitionLanguages = ["en_US"]

            let orientations: [CGImagePropertyOrientation] = [.up, .right, .left, .down]
            let rois: [CGRect] = [
                CGRect(x: 0.1, y: 0.74, width: 0.8, height: 0.22),
                CGRect(x: 0.15, y: 0.64, width: 0.7, height: 0.3)
            ]

            func textVariants(for image: CGImage) -> [CGImage] {
                var imgs: [CGImage] = [image]
                if let up = upscaleImage(image, maxDimension: 2000, maxScale: 3.0) { imgs.append(up) }
                if let mono = highContrastMono(image) { imgs.append(mono) }
                if let strong = strongMonoThreshold(image, threshold: 0.55) { imgs.append(strong) }
                return imgs
            }

            for orientation in orientations {
                for img in textVariants(for: cgImage) {
                    let handler = VNImageRequestHandler(cgImage: img, orientation: orientation)
                    try? handler.perform([request])
                    if let text = firstDigits(from: request.results ?? []) {
                        return text
                    }
                }

                for roi in rois {
                    let width = CGFloat(cgImage.width)
                    let height = CGFloat(cgImage.height)
                    let rect = CGRect(
                        x: roi.origin.x * width,
                        y: roi.origin.y * height,
                        width: roi.width * width,
                        height: roi.height * height
                    )
                    if let crop = cgImage.cropping(to: rect) {
                        for img in textVariants(for: crop) {
                            let handler = VNImageRequestHandler(cgImage: img, orientation: orientation)
                            try? handler.perform([request])
                            if let text = firstDigits(from: request.results ?? []) {
                                return text
                            }
                        }
                    }
                }
            }
            return nil
        }

        private func firstDigits(from observations: [VNObservation]) -> String? {
            let raw = observations
                .compactMap { ($0 as? VNRecognizedTextObservation)?.topCandidates(1).first?.string }
            let digitsOnly = raw
                .map { cand in cand.filter { $0.isNumber } }
                .filter { !$0.isEmpty }

            if let exact = digitsOnly.first(where: { (8...14).contains($0.count) }) {
                return exact
            }
            return digitsOnly.first
        }

        private func performVisionRequest(on pixelBuffer: CVPixelBuffer,
                                          orientation: CGImagePropertyOrientation) throws -> String? {
            let request = makeBarcodeRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
            try handler.perform([request])

            guard let observations = request.results else { return nil }
            return observations
                .compactMap { $0.payloadStringValue }
                .first(where: { !$0.isEmpty })
        }

        private func makeBarcodeRequest() -> VNDetectBarcodesRequest {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.ean8, .ean13, .upce, .code128, .code39, .code93, .qr]
            if let latest = VNDetectBarcodesRequest.supportedRevisions.max() {
                request.revision = latest
            }
            return request
        }

        private func boostedImage(from cgImage: CGImage) -> CGImage? {
            let width = CGFloat(cgImage.width)
            let height = CGFloat(cgImage.height)
            let maxDimension: CGFloat = 2400
            let scale = max(1.2, min(maxDimension / max(width, height), 3.0))

            let ciImage = CIImage(cgImage: cgImage)
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    "inputScale": scale,
                    "inputAspectRatio": width / height
                ])
                .applyingFilter("CIColorControls", parameters: [
                    "inputSaturation": 0.0,
                    "inputContrast": 1.8
                ])
                .applyingFilter("CISharpenLuminance", parameters: [
                    "inputSharpness": 0.6
                ])

            return ciContext.createCGImage(ciImage, from: ciImage.extent)
        }

        private func gammaAdjust(_ cgImage: CGImage, power: CGFloat) -> CGImage? {
            let ciImage = CIImage(cgImage: cgImage)
                .applyingFilter("CIGammaAdjust", parameters: ["inputPower": power])
            return ciContext.createCGImage(ciImage, from: ciImage.extent)
        }

        private func upscaleImage(_ cgImage: CGImage, maxDimension: CGFloat = 3200, maxScale: CGFloat = 3.5) -> CGImage? {
            let width = CGFloat(cgImage.width)
            let height = CGFloat(cgImage.height)
            let scale = min(maxDimension / max(width, height), maxScale)
            guard scale > 1 else { return nil }

            let ciImage = CIImage(cgImage: cgImage)
                .applyingFilter("CILanczosScaleTransform", parameters: [
                    "inputScale": scale,
                    "inputAspectRatio": width / height
                ])
            return ciContext.createCGImage(ciImage, from: ciImage.extent)
        }

        private func highContrastMono(_ cgImage: CGImage) -> CGImage? {
            let ciImage = CIImage(cgImage: cgImage)
                .applyingFilter("CIColorControls", parameters: [
                    "inputSaturation": 0.0,
                    "inputContrast": 1.8
                ])
                .applyingFilter("CIUnsharpMask", parameters: [
                    "inputRadius": 1.0,
                    "inputIntensity": 0.8
                ])
            return ciContext.createCGImage(ciImage, from: ciImage.extent)
        }

        private func strongMonoThreshold(_ cgImage: CGImage, threshold: CGFloat = 0.58) -> CGImage? {
            let ciImage = CIImage(cgImage: cgImage)
                .applyingFilter("CIColorControls", parameters: [
                    "inputSaturation": 0.0,
                    "inputContrast": 2.4,
                    "inputBrightness": 0.05
                ])
                .applyingFilter("CIExposureAdjust", parameters: ["inputEV": 0.25])

            let clamped = ciImage.applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: threshold, y: threshold, z: threshold, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])

            return ciContext.createCGImage(clamped, from: clamped.extent)
        }

        private func morphologicalClose(_ cgImage: CGImage, radius: CGFloat = 2.2) -> CGImage? {
            let ciImage = CIImage(cgImage: cgImage)
                .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": radius])
                .applyingFilter("CIMorphologyMinimum", parameters: ["inputRadius": radius])
            return ciContext.createCGImage(ciImage, from: ciImage.extent)
        }

        private func sharpenImage(_ cgImage: CGImage, radius: CGFloat = 1.0, intensity: CGFloat = 1.0) -> CGImage? {
            let ciImage = CIImage(cgImage: cgImage)
                .applyingFilter("CIUnsharpMask", parameters: [
                    "inputRadius": radius,
                    "inputIntensity": intensity
                ])
            return ciContext.createCGImage(ciImage, from: ciImage.extent)
        }

        private func bottomCenterCrop(_ cgImage: CGImage, heightFraction: CGFloat, widthFraction: CGFloat) -> CGImage? {
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
    }
}

final class PreviewContainerView: UIView {
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }
}
