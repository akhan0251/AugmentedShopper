#if BARCODE_SCRIPT
import Foundation
import Vision
import CoreImage
import ImageIO
import CoreGraphics

/// Simple CLI helper to test barcode detection on a still image using
/// the same pre-processing stack as the in-app scanner.
///
/// Usage:
///   swift -D BARCODE_SCRIPT RayBanPriceScanner/RayBanPriceScanner/Scripts/BarcodeTest.swift <path-to-image>

@main
struct BarcodeScript {
    static func main() {
        guard CommandLine.arguments.count > 1 else {
            print("Usage: swift -D BARCODE_SCRIPT BarcodeTest.swift <path-to-image>")
            return
        }

        let path = CommandLine.arguments[1]
        let url = URL(fileURLWithPath: path)
        guard let cgImage = loadCGImage(from: url) else {
            print("Could not load image at \(path)")
            return
        }

        let detector = Detector(verbose: ProcessInfo.processInfo.environment["VERBOSE"] != nil)
        if let payload = detector.detectPayload(in: cgImage) {
            print("✅ Detected barcode: \(payload)")
        } else if let ocr = detector.recognizeDigits(in: cgImage) {
            print("⚠️ No barcode detected. OCR fallback read digits: \(ocr)")
        } else {
            print("⚠️ No barcode detected.")
        }
    }
}

private func loadCGImage(from url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

// MARK: - Detector logic (mirrors QRScannerView fallback)

final class Detector {
    private let verbose: Bool
    private let usesCPUOnly: Bool
    private let ciContext = CIContext()

    init(verbose: Bool = false, usesCPUOnly: Bool = true) {
        self.verbose = verbose
        self.usesCPUOnly = usesCPUOnly
    }

    func detectPayload(in cgImage: CGImage) -> String? {
        let orientations: [CGImagePropertyOrientation] = [
            .right, .up, .left, .down, .rightMirrored, .upMirrored, .leftMirrored, .downMirrored
        ]

        if let quick = quickDetectOnOriginal(cgImage, orientations: orientations) {
            return quick
        }

        if let band = detectBottomBand(in: cgImage, orientations: orientations) {
            return band
        }

        let variants = barcodeVariants(from: cgImage)
        for orientation in orientations {
            for variant in variants {
                if let payload = performBarcodeDetection(on: variant, orientation: orientation) {
                    return payload
                }
            }
        }

        return nil
    }

    /// OCR fallback to read printed digits beneath the barcode.
    func recognizeDigits(in cgImage: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.02
        request.customWords = []
        request.recognitionLanguages = ["en_US"]

        let orientations: [CGImagePropertyOrientation] = [.up, .right, .left, .down]
        let rois: [CGRect] = [
            CGRect(x: 0.1, y: 0.75, width: 0.8, height: 0.22),
            CGRect(x: 0.15, y: 0.68, width: 0.7, height: 0.28)
        ]

        func variants(for image: CGImage) -> [CGImage] {
            var imgs: [CGImage] = [image]
            if let up = upscaleImage(image, maxDimension: 2000, maxScale: 3.0) { imgs.append(up) }
            if let mono = highContrastMono(image) { imgs.append(mono) }
            if let strong = strongMonoThreshold(image, threshold: 0.55) { imgs.append(strong) }
            return imgs
        }

        for orientation in orientations {
            for img in variants(for: cgImage) {
                let results = perform(request: request, on: img, orientation: orientation)
                if let text = firstDigits(from: results) {
                    return text
                }
            }

            // Try region-of-interest crops for bottom text band.
            for roi in rois {
                let width = CGFloat(cgImage.width)
                let height = CGFloat(cgImage.height)
                let rect = CGRect(x: roi.origin.x * width,
                                  y: roi.origin.y * height,
                                  width: roi.width * width,
                                  height: roi.height * height)
                if let crop = cgImage.cropping(to: rect) {
                    for img in variants(for: crop) {
                        let results = perform(request: request, on: img, orientation: orientation)
                        if let text = firstDigits(from: results) {
                            return text
                        }
                    }
                }
            }
        }
        return nil
    }

    private func firstDigits(from observations: [VNObservation]) -> String? {
        let rawCandidates = observations
            .compactMap { ($0 as? VNRecognizedTextObservation)?.topCandidates(1).first?.string }

        let normalized = rawCandidates.map { cand -> String in
            let digits = cand.filter { $0.isNumber }
            return digits
        }.filter { !$0.isEmpty }

        if let exact = normalized.first(where: { (8...14).contains($0.count) }) {
            return exact
        }

        if let raw = rawCandidates.first {
            if verbose {
                print("🔎 OCR candidates (raw): \(rawCandidates)")
                print("🔎 OCR candidates (digits only): \(normalized)")
            }
            let digits = raw.filter { $0.isNumber }
            return digits.isEmpty ? nil : digits
        }
        return nil
    }

    private func performBarcodeDetection(on cgImage: CGImage,
                                         orientation: CGImagePropertyOrientation) -> String? {
        let request = makeBarcodeRequest()
        let results = perform(request: request, on: cgImage, orientation: orientation)
        if verbose {
            let barcodeResults = results.compactMap { $0 as? VNBarcodeObservation }
            let payloads = barcodeResults.compactMap { $0.payloadStringValue }
            let symbologies = barcodeResults.map { $0.symbology.rawValue }
            print("↪︎ Orientation \(orientation) results: \(results.count), payloads: \(payloads), symbologies: \(symbologies)")
        }

        if let payload = (results as? [VNBarcodeObservation])?
            .compactMap({ $0.payloadStringValue })
            .first(where: { !$0.isEmpty }) {
            return payload.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func makeBarcodeRequest() -> VNDetectBarcodesRequest {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.ean8, .ean13, .upce, .code128, .code39, .code93, .qr]
        if let latest = VNDetectBarcodesRequest.supportedRevisions.max() {
            request.revision = latest
        }
        request.usesCPUOnly = usesCPUOnly
        return request
    }

    private func quickDetectOnOriginal(_ cgImage: CGImage,
                                       orientations: [CGImagePropertyOrientation]) -> String? {
        var variants = [cgImage]
        if let up = upscaleImage(cgImage, maxDimension: 4800) { variants.append(up) }
        if let mono = highContrastMono(cgImage) { variants.append(mono) }
        if let strong = strongMonoThreshold(cgImage, threshold: 0.58) { variants.append(strong) }
        if let upMono = variants.first.flatMap({ highContrastMono($0) }) { variants.append(upMono) }
        if let upStrong = variants.first.flatMap({ strongMonoThreshold($0, threshold: 0.58) }) { variants.append(upStrong) }
        if let strongLow = strongMonoThreshold(cgImage, threshold: 0.5) { variants.append(strongLow) }
        if let strongHigh = strongMonoThreshold(cgImage, threshold: 0.65) { variants.append(strongHigh) }
        if let boosted = boostedImage(from: cgImage) { variants.append(boosted) }

        for orientation in orientations {
            for variant in variants {
                if let payload = performBarcodeDetection(on: variant, orientation: orientation) {
                    return payload
                }
            }
        }
        return nil
    }

    private func detectBottomBand(in cgImage: CGImage,
                                  orientations: [CGImagePropertyOrientation]) -> String? {
        let bandHeights: [CGFloat] = [0.65, 0.55, 0.45, 0.35, 0.25, 0.18]
        let bandWidths: [CGFloat] = [1.0, 0.9, 0.78, 0.68]
        var bandVariants: [CGImage] = []

        for h in bandHeights {
            for w in bandWidths {
                if let band = bottomCenterCrop(cgImage, heightFraction: h, widthFraction: w) {
                    bandVariants.append(band)
                    if let up = upscaleImage(band, maxDimension: 3800) { bandVariants.append(up) }
                    if let mono = highContrastMono(band) { bandVariants.append(mono) }
                    if let strong = strongMonoThreshold(band, threshold: 0.58) { bandVariants.append(strong) }
                    if let strongLow = strongMonoThreshold(band, threshold: 0.5) { bandVariants.append(strongLow) }
                    if let strongHigh = strongMonoThreshold(band, threshold: 0.65) { bandVariants.append(strongHigh) }
                    if let morph = morphologicalClose(band, radius: 3.0) { bandVariants.append(morph) }
                    if let sharp = sharpenImage(band, radius: 1.2, intensity: 1.0) { bandVariants.append(sharp) }
                    if let gammaDark = gammaAdjust(band, power: 0.9) { bandVariants.append(gammaDark) }
                    if let gammaBright = gammaAdjust(band, power: 1.15) { bandVariants.append(gammaBright) }
                }
            }
        }

        for orientation in orientations {
            for variant in bandVariants {
                if let payload = performBarcodeDetection(on: variant, orientation: orientation) {
                    return payload
                }
            }
        }
        return nil
    }

    private func barcodeVariants(from cgImage: CGImage) -> [CGImage] {
        var results: [CGImage] = []

        if let strong = strongMonoThreshold(cgImage, threshold: 0.58) { results.append(strong) }
        if let strongLow = strongMonoThreshold(cgImage, threshold: 0.5) { results.append(strongLow) }
        if let strongHigh = strongMonoThreshold(cgImage, threshold: 0.65) { results.append(strongHigh) }
        if let bin = highContrastMono(cgImage) { results.append(bin) }
        if let morph = morphologicalClose(cgImage, radius: 2.5) { results.append(morph) }
        if let dark = gammaAdjust(cgImage, power: 0.85) { results.append(dark) }
        if let bright = gammaAdjust(cgImage, power: 1.2) { results.append(bright) }
        if let sharp = sharpenImage(cgImage, radius: 1.1, intensity: 1.0) { results.append(sharp) }
        if let equalized = equalizedMono(cgImage) { results.append(equalized) }

        results.append(cgImage)
        if let boosted = boostedImage(from: cgImage) { results.append(boosted) }
        if let upscaled = upscaleImage(cgImage, maxDimension: 4200) { results.append(upscaled) }

        for fraction in [0.85, 0.7, 0.55, 0.4] {
            if let crop = centerCrop(cgImage, fraction: fraction) {
                results.append(crop)
                if let upCrop = upscaleImage(crop, maxDimension: 3200) {
                    results.append(upCrop)
                }
            }
        }
        for heightFraction in [0.55, 0.4, 0.3, 0.2] {
            if let band = bottomCenterCrop(cgImage, heightFraction: heightFraction, widthFraction: 0.8) {
                results.append(band)
                if let upBand = upscaleImage(band, maxDimension: 3200) {
                    results.append(upBand)
                }
            }
        }

        return results
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

    private func gammaAdjust(_ cgImage: CGImage, power: CGFloat) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": power])
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    private func equalizedMono(_ cgImage: CGImage) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
        let mono = ciImage.applyingFilter("CIPhotoEffectMono")
        let histo = mono.applyingFilter("CIAreaHistogram", parameters: [
            "inputExtent": CIVector(x: mono.extent.origin.x, y: mono.extent.origin.y, z: mono.extent.size.width, w: mono.extent.size.height),
            "inputCount": 256
        ])
        let equalized = histo.applyingFilter("CIHistogramDisplayFilter", parameters: [
            "inputHeight": 256
        ])
        return ciContext.createCGImage(equalized, from: equalized.extent)
    }

    private func centerCrop(_ cgImage: CGImage, fraction: CGFloat) -> CGImage? {
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

    private func perform(request: VNRequest,
                         on cgImage: CGImage,
                         orientation: CGImagePropertyOrientation) -> [VNObservation] {
        if let pixelBuffer = pixelBuffer(from: cgImage) {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
            do {
                try handler.perform([request])
                return request.results ?? []
            } catch {
                if verbose { print("❌ Vision error (pixelBuffer): \(error.localizedDescription)") }
            }
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
        do {
            try handler.perform([request])
            return request.results ?? []
        } catch {
            if verbose { print("❌ Vision error (cgImage): \(error.localizedDescription)") }
            return []
        }
    }

    private func pixelBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
        let width = cgImage.width
        let height = cgImage.height
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary,
                                         &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else {
            if verbose { print("❌ Could not create CVPixelBuffer (status \(status))") }
            return nil
        }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pb) else {
            if verbose { print("❌ CVPixelBuffer baseAddress nil") }
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        guard let context = CGContext(data: baseAddress,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            if verbose { print("❌ Could not create CGContext for CVPixelBuffer") }
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pb
    }
}
#endif
