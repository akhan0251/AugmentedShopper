import MWDATCamera
import MWDATCore
import SwiftUI
import Combine

enum StreamingStatus {
    case streaming
    case waiting
    case stopped
}

enum FrameRatePreset: CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: Self { self }

    var label: String {
        switch self {
        case .low: return "Min"
        case .medium: return "Med"
        case .high: return "Max"
        }
    }

    var framesPerSecond: UInt {
        switch self {
        case .low: return 8
        case .medium: return 12
        case .high: return 15
        }
    }
}

@MainActor
class StreamSessionViewModel: ObservableObject {
    @Published var currentVideoFrame: UIImage?
    @Published var hasReceivedFirstFrame: Bool = false
    @Published var streamingStatus: StreamingStatus = .stopped
    @Published var showError: Bool = false
    @Published var errorMessage: String = ""

    var isStreaming: Bool {
        streamingStatus == .streaming
    }

    var isSessionActive: Bool {
        streamingStatus != .stopped
    }

    @Published var activeTimeLimit: StreamTimeLimit = .noLimit
    @Published var remainingTime: TimeInterval = 0

    @Published var capturedPhoto: UIImage?
    @Published var showPhotoPreview: Bool = false

    @Published var frameRatePreset: FrameRatePreset = .high
    @Published var statusBanner: String = ""

    private var timerTask: Task<Void, Never>?
    private var streamSession: StreamSession?
    private var stateListenerToken: AnyListenerToken?
    private var videoFrameListenerToken: AnyListenerToken?
    private var errorListenerToken: AnyListenerToken?
    private var photoDataListenerToken: AnyListenerToken?
    private var isTransitioning = false
    private var lastUserToggle = Date.distantPast
    private let wearables: WearablesInterface
    private let enableStreamDebugLogging = false

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        log("📡 StreamSessionViewModel init (reg state: \(wearables.registrationState))")
        rebuildStreamSession()
    }

    func updateFrameRatePreset(_ preset: FrameRatePreset) {
        Task { await updateFrameRatePresetAsync(preset) }
    }

    func updateFrameRatePresetAsync(_ preset: FrameRatePreset) async {
        guard preset != frameRatePreset else { return }
        frameRatePreset = preset
        log("⚙️ Updating FPS preset to \(preset.label) (\(preset.framesPerSecond) fps).")
        isTransitioning = true
        await stopSessionAwaiting()
        configureStreamSession(with: preset)
        streamingStatus = .stopped
        isTransitioning = false
    }

    func handleStartStreaming() async {
        guard canToggleStream() else { return }
        isTransitioning = true
        statusBanner = "Connecting to glasses…"
        let permission = Permission.camera
        do {
            let status = try await wearables.checkPermissionStatus(permission)
            if status == .granted {
                await prepareSessionForStart()
                log("▶️ Starting session (permission already granted)")
                startSession()
                return
            }
            let requestStatus = try await wearables.requestPermission(permission)
            if requestStatus == .granted {
                await prepareSessionForStart()
                log("▶️ Starting session (permission newly granted)")
                startSession()
                return
            }
            showError("Permission denied")
            streamingStatus = .stopped
            statusBanner = "Permission denied. Grant access to start streaming."
        } catch {
            showError("Permission error: \(error.localizedDescription)")
            streamingStatus = .stopped
            statusBanner = "Permission error: \(error.localizedDescription)"
        }
        isTransitioning = false
    }

    func startSession() {
        activeTimeLimit = .noLimit
        remainingTime = 0
        stopTimer()
        streamingStatus = .waiting
        log("ℹ️ startSession called (fps: \(frameRatePreset.framesPerSecond))")
        statusBanner = "Starting stream…"

        guard let session = streamSession ?? rebuildAndReturnSession() else {
            showError("Unable to create stream session.")
            streamingStatus = .stopped
            statusBanner = "Unable to create stream session."
            return
        }

        Task { await session.start() }
    }

    private func showError(_ message: String) {
        errorMessage = message
        showError = true
    }

    func stopSession() {
        guard canToggleStream() else { return }
        isTransitioning = true
        statusBanner = "Stopping stream…"
        stopTimer()
        guard let sessionToStop = streamSession else { return }
        Task { await sessionToStop.stop() }
    }

    private func stopSessionAwaiting() async {
        stopTimer()
        let sessionToStop = streamSession
        log("⏹️ stopSessionAwaiting called")
        await sessionToStop?.stop()
        streamingStatus = .stopped
        tearDownAndClearSession()
        isTransitioning = false
        statusBanner = "Stream stopped. Tap Play to start."
    }

    /// User-initiated reset that stops and rebuilds the session without auto-starting.
    func resetSessionForUser() async {
        guard canToggleStream() else { return }
        isTransitioning = true
        statusBanner = "Resetting stream session…"
        await stopSessionAwaiting()
        configureStreamSession(with: frameRatePreset)
        statusBanner = "Session reset. Tap Play to start."
        isTransitioning = false
    }

    private func handleStartStreamingIfNeeded(_ shouldStart: Bool) async {
        guard shouldStart else { return }
        log("▶️ Restarting stream after config change")
        await handleStartStreaming()
    }

    func dismissError() {
        showError = false
        errorMessage = ""
    }

    func setTimeLimit(_ limit: StreamTimeLimit) {
        activeTimeLimit = limit
        remainingTime = limit.durationInSeconds ?? 0

        if limit.isTimeLimited {
            startTimer()
        } else {
            stopTimer()
        }
    }

    func capturePhoto() {
        streamSession?.capturePhoto(format: .jpeg)
    }

    /// Ensures the stream is running, then captures a still after a brief warmup.
    func captureHighQualityFrame() async {
        if !isStreaming {
            await handleStartStreaming()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        streamSession?.capturePhoto(format: .jpeg)
    }

    /// Forcefully stop any existing session, rebuild, and start fresh at max quality.
    func startFreshStream() async {
        await stopSessionAwaiting()
        rebuildStreamSession()
        frameRatePreset = .high
        await handleStartStreaming()
    }

    func dismissPhotoPreview() {
        showPhotoPreview = false
        capturedPhoto = nil
    }

    private func startTimer() {
        stopTimer()
        timerTask = Task { @MainActor [weak self] in
            while let self, remainingTime > 0 {
                try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
                guard !Task.isCancelled else { break }
                remainingTime -= 1
            }
            if let self, !Task.isCancelled {
                stopSession()
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func updateStatusFromState(_ state: StreamSessionState) {
        switch state {
        case .stopped:
            currentVideoFrame = nil
            streamingStatus = .stopped
            isTransitioning = false
            statusBanner = ""
        case .waitingForDevice, .starting, .stopping, .paused:
            streamingStatus = .waiting
            isTransitioning = true
            statusBanner = ""
        case .streaming:
            streamingStatus = .streaming
            isTransitioning = false
            statusBanner = ""
        }
    }

    private func formatStreamingError(_ error: StreamSessionError) -> String {
        switch error {
        case .internalError:
            return "An internal error occurred. Please try again."
        case .deviceNotFound:
            return "Device not found. Please ensure your device is connected."
        case .deviceNotConnected:
            return "Device not connected. Please check your connection and try again."
        case .timeout:
            return "The operation timed out. Please try again."
        case .videoStreamingError:
            return "Video streaming failed. Please try again."
        case .audioStreamingError:
            return "Audio streaming failed. Please try again."
        case .permissionDenied:
            return "Camera permission denied. Please grant permission in Settings."
        @unknown default:
            return "An unknown streaming error occurred."
        }
    }

    private func configureStreamSession(with preset: FrameRatePreset) {
        tearDownAndClearSession()
        streamSession = StreamSession(
            streamSessionConfig: StreamSessionViewModel.makeConfig(for: preset),
            deviceSelector: AutoDeviceSelector(wearables: wearables)
        )
        bindStreamSession()
        streamingStatus = .stopped
    }

    private func prepareSessionForStart() async {
        if isSessionActive {
            await stopSessionAwaiting()
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private func bindStreamSession() {
        guard let streamSession else { return }

        stateListenerToken = streamSession.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateStatusFromState(state)
                self.log("🔄 Stream state updated: \(state)")
            }
        }

        videoFrameListenerToken = streamSession.videoFramePublisher.listen { [weak self] videoFrame in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let image = videoFrame.makeUIImage() {
                    self.currentVideoFrame = image
                    if !self.hasReceivedFirstFrame {
                        self.hasReceivedFirstFrame = true
                    }
                }
            }
        }

        errorListenerToken = streamSession.errorPublisher.listen { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let newErrorMessage = self.formatStreamingError(error)
                if newErrorMessage != self.errorMessage {
                    self.showError(newErrorMessage)
                }
                log("⚠️ Stream error: \(error)")
                self.statusBanner = newErrorMessage
            }
        }

        photoDataListenerToken = streamSession.photoDataPublisher.listen { [weak self] photoData in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let uiImage = UIImage(data: photoData.data) {
                    self.capturedPhoto = uiImage
                    self.showPhotoPreview = true
                    log("📸 Photo captured from streamSession")
                }
            }
        }

        updateStatusFromState(streamSession.state)
    }

    private func tearDownAndClearSession() {
        stateListenerToken = nil
        videoFrameListenerToken = nil
        errorListenerToken = nil
        photoDataListenerToken = nil
        streamSession = nil
        log("🧹 StreamSessionViewModel teardown listeners")
    }

    private func rebuildStreamSession() {
        configureStreamSession(with: .high)
    }

    private func rebuildAndReturnSession() -> StreamSession? {
        rebuildStreamSession()
        return streamSession
    }

    private static func makeConfig(for preset: FrameRatePreset) -> StreamSessionConfig {
        StreamSessionConfig(
            videoCodec: VideoCodec.raw,
            resolution: StreamingResolution.high,
            frameRate: preset.framesPerSecond)
    }

    private func log(_ message: @autoclosure () -> String) {
        guard enableStreamDebugLogging else { return }
        print(message())
    }

    private func canToggleStream() -> Bool {
        let now = Date()
        if isTransitioning {
            return false
        }
        if now.timeIntervalSince(lastUserToggle) < 0.6 {
            return false
        }
        lastUserToggle = now
        return true
    }
}
