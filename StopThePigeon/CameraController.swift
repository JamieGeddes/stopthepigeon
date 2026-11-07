@preconcurrency import AVFoundation
import Observation

/// Owns the capture session: picks a camera (preferring an iPhone via Continuity
/// Camera), runs the live preview and captures full-resolution stills.
@MainActor
@Observable
final class CameraController {
    enum Status: Equatable {
        case starting
        case unauthorised
        case noCamera
        case running
        /// The camera stopped sending video (for example the iPhone locked or moved
        /// away). The app reconnects automatically when it comes back.
        case disconnected(String)
        case failed(String)
    }

    struct Capability {
        var supported = false
        var locked = false
    }

    private(set) var status: Status = .starting
    private(set) var devices: [AVCaptureDevice] = []
    private(set) var selectedDeviceID: String?
    private(set) var videoAspect: Double = 4.0 / 3.0
    private(set) var photoSizeDescription = ""
    private(set) var effectsWarning: String?
    private(set) var focus = Capability()
    private(set) var exposure = Capability()
    private(set) var whiteBalance = Capability()

    let session = AVCaptureSession()
    /// Renders the live view with effects applied (green screen).
    let effectPreview = EffectPreviewRenderer()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.clumsypenguin.StopThePigeon.session")
    private let videoQueue = DispatchQueue(label: "com.clumsypenguin.StopThePigeon.video", qos: .userInteractive)
    private var inFlightCaptures: [Int64: PhotoCaptureDelegate] = [:]
    private var observers: [NSObjectProtocol] = []
    private var healthTimer: Timer?
    /// The format chosen for the current device, and how often it has had to be
    /// restored after the camera switched modes by itself. Only touched on `sessionQueue`.
    @ObservationIgnored nonisolated(unsafe) private var preferredFormat: AVCaptureDevice.Format?
    @ObservationIgnored nonisolated(unsafe) private var formatRestores = 0
    private var isReconnecting = false

    var selectedDevice: AVCaptureDevice? {
        devices.first { $0.uniqueID == selectedDeviceID }
    }

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                status = .unauthorised
                return
            }
        default:
            status = .unauthorised
            return
        }

        // Centre Stage reframes the shot automatically, which ruins stop motion.
        AVCaptureDevice.centerStageControlMode = .cooperative
        AVCaptureDevice.isCenterStageEnabled = false

        observeDeviceChanges()
        refreshDevices()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshEffectsWarning()
                self?.checkHealth()
            }
        }
    }

    func selectDevice(id: String) {
        configureSession(deviceID: id, quietly: false)
    }

    /// Sets up the session for a device. `quietly` keeps the current status while
    /// retrying after a disconnect, so the UI doesn't flicker between states.
    private func configureSession(deviceID id: String, quietly: Bool) {
        guard let device = devices.first(where: { $0.uniqueID == id }) else { return }
        selectedDeviceID = id
        if !quietly { status = .starting }
        let deviceName = device.localizedName

        let format = Self.bestPhotoFormat(for: device)
        let session = session
        let photoOutput = photoOutput
        let videoOutput = videoOutput
        let effectPreview = effectPreview
        let videoQueue = videoQueue

        sessionQueue.async {
            do {
                session.beginConfiguration()
                for input in session.inputs { session.removeInput(input) }
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw CameraError.cannotUseDevice }
                session.addInput(input)
                if !session.outputs.contains(photoOutput) {
                    guard session.canAddOutput(photoOutput) else { throw CameraError.cannotUseDevice }
                    session.addOutput(photoOutput)
                }
                // Optional: frames for the effects preview. Capture still works without it.
                if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
                    videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    videoOutput.alwaysDiscardsLateVideoFrames = true
                    videoOutput.setSampleBufferDelegate(effectPreview, queue: videoQueue)
                    session.addOutput(videoOutput)
                }
                if let format {
                    try device.lockForConfiguration()
                    device.activeFormat = format
                    device.unlockForConfiguration()
                } else {
                    session.sessionPreset = .photo
                }
                session.commitConfiguration()
                self.preferredFormat = format
                self.formatRestores = 0

                if !session.isRunning { session.startRunning() }

                let info = Self.syncFormat(device: device, photoOutput: photoOutput, restoring: nil)
                let live = Self.isLive(session: session, photoOutput: photoOutput)
                Task { @MainActor in
                    self.isReconnecting = false
                    guard live else {
                        self.status = .disconnected(deviceName)
                        return
                    }
                    self.apply(info)
                    self.status = .running
                    self.refreshCapabilities()
                    self.refreshEffectsWarning()
                }
            } catch {
                session.commitConfiguration()
                Task { @MainActor in
                    self.isReconnecting = false
                    self.status = quietly ? .disconnected(deviceName) : .failed(error.localizedDescription)
                }
            }
        }
    }

    /// True if the session is running and the photo output has a live video connection.
    /// Capturing without one throws an Objective-C exception.
    nonisolated private static func isLive(session: AVCaptureSession, photoOutput: AVCapturePhotoOutput) -> Bool {
        guard session.isRunning, let connection = photoOutput.connection(with: .video) else { return false }
        return connection.isEnabled && connection.isActive
    }

    // MARK: Format

    struct FormatInfo {
        var videoAspect: Double
        var photoDimensions: CMVideoDimensions
    }

    /// Makes the photo output's size match the device's *current* format. The camera can
    /// switch formats by itself (for example after the iPhone locks), and capturing with
    /// a size the active format doesn't support throws. With `restoring`, first switches
    /// back to that format.
    nonisolated private static func syncFormat(
        device: AVCaptureDevice,
        photoOutput: AVCapturePhotoOutput,
        restoring preferred: AVCaptureDevice.Format?
    ) -> FormatInfo? {
        if let preferred, device.activeFormat != preferred, device.formats.contains(preferred) {
            _ = SPCatchException {
                if (try? device.lockForConfiguration()) != nil {
                    device.activeFormat = preferred
                    device.unlockForConfiguration()
                }
            }
        }
        let format = device.activeFormat
        guard let largest = largestPhotoDimensions(in: format) else { return nil }
        let current = photoOutput.maxPhotoDimensions
        if current.width != largest.width || current.height != largest.height {
            if SPCatchException({ photoOutput.maxPhotoDimensions = largest }) != nil { return nil }
        }
        let video = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let aspect = video.height > 0 ? Double(video.width) / Double(video.height) : 4.0 / 3.0
        return FormatInfo(videoAspect: aspect, photoDimensions: largest)
    }

    private func apply(_ info: FormatInfo?) {
        guard let info else { return }
        if videoAspect != info.videoAspect { videoAspect = info.videoAspect }
        let description = "\(info.photoDimensions.width) × \(info.photoDimensions.height)"
        if photoSizeDescription != description { photoSizeDescription = description }
    }

    nonisolated private static func currentDevice(of session: AVCaptureSession) -> AVCaptureDevice? {
        session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }.first
    }

    // MARK: Connection health

    /// Marks the camera disconnected if video has stopped, and retries while it's away.
    private func checkHealth() {
        guard let id = selectedDeviceID else { return }
        switch status {
        case .running:
            let session = session
            let photoOutput = photoOutput
            sessionQueue.async {
                guard Self.isLive(session: session, photoOutput: photoOutput) else {
                    Task { @MainActor in self.handleLostConnection() }
                    return
                }
                guard let device = Self.currentDevice(of: session) else { return }
                // Restore the chosen format if the camera drifted, but give up after a few
                // attempts in case the camera insists, rather than restarting video forever.
                var preferred = self.preferredFormat
                if let wanted = preferred, device.activeFormat != wanted {
                    self.formatRestores += 1
                    if self.formatRestores > 3 { preferred = nil }
                }
                let info = Self.syncFormat(device: device, photoOutput: photoOutput, restoring: preferred)
                Task { @MainActor in self.apply(info) }
            }
        case .disconnected:
            guard !isReconnecting, devices.contains(where: { $0.uniqueID == id }) else { return }
            isReconnecting = true
            configureSession(deviceID: id, quietly: true)
        default:
            break
        }
    }

    private func handleLostConnection() {
        guard status == .running else { return }
        status = .disconnected(selectedDevice?.localizedName ?? "Camera")
        failInFlightCaptures()
    }

    private func failInFlightCaptures() {
        for delegate in inFlightCaptures.values { delegate.finish(.failure(CameraError.disconnected)) }
        inFlightCaptures.removeAll()
    }

    /// Captures a still and returns its encoded data plus a file extension.
    func capturePhoto() async throws -> (data: Data, fileExtension: String) {
        guard status == .running else { throw CameraError.notRunning }

        let useJPEG = photoOutput.availablePhotoCodecTypes.contains(.jpeg)
        let settings = useJPEG
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            : AVCapturePhotoSettings()

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let delegate = PhotoCaptureDelegate { [weak self] result in
                Task { @MainActor in self?.inFlightCaptures[settings.uniqueID] = nil }
                continuation.resume(with: result)
            }
            inFlightCaptures[settings.uniqueID] = delegate
            let session = session
            let photoOutput = photoOutput
            sessionQueue.async {
                guard Self.isLive(session: session, photoOutput: photoOutput) else {
                    delegate.finish(.failure(CameraError.disconnected))
                    Task { @MainActor in self.handleLostConnection() }
                    return
                }
                // Size the photo for the format that's active right now.
                if let device = Self.currentDevice(of: session) {
                    let info = Self.syncFormat(device: device, photoOutput: photoOutput, restoring: nil)
                    if let dims = info?.photoDimensions { settings.maxPhotoDimensions = dims }
                    Task { @MainActor in self.apply(info) }
                }
                // Anything AVFoundation still rejects becomes an error message, not a crash.
                if let exception = SPCatchException({ photoOutput.capturePhoto(with: settings, delegate: delegate) }) {
                    delegate.finish(.failure(CameraError.captureFailed(exception.reason ?? exception.name.rawValue)))
                    if !Self.isLive(session: session, photoOutput: photoOutput) {
                        Task { @MainActor in self.handleLostConnection() }
                    }
                }
            }
            // If the camera vanishes mid-capture the delegate may never be called.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                delegate.finish(.failure(CameraError.timedOut))
            }
        }
        return (data, useJPEG ? "jpg" : "heic")
    }

    // MARK: Locks

    func setFocusLocked(_ locked: Bool) {
        configure { device in
            let mode: AVCaptureDevice.FocusMode = locked ? .locked : .continuousAutoFocus
            if device.isFocusModeSupported(mode) { device.focusMode = mode }
        }
    }

    func setExposureLocked(_ locked: Bool) {
        configure { device in
            let mode: AVCaptureDevice.ExposureMode = locked ? .locked : .continuousAutoExposure
            if device.isExposureModeSupported(mode) { device.exposureMode = mode }
        }
    }

    func setWhiteBalanceLocked(_ locked: Bool) {
        configure { device in
            let mode: AVCaptureDevice.WhiteBalanceMode = locked ? .locked : .continuousAutoWhiteBalance
            if device.isWhiteBalanceModeSupported(mode) { device.whiteBalanceMode = mode }
        }
    }

    private func configure(_ change: (AVCaptureDevice) -> Void) {
        guard let device = selectedDevice else { return }
        do {
            try device.lockForConfiguration()
            change(device)
            device.unlockForConfiguration()
        } catch {
            status = .failed(error.localizedDescription)
        }
        refreshCapabilities()
    }

    private func refreshCapabilities() {
        guard let device = selectedDevice else {
            focus = Capability(); exposure = Capability(); whiteBalance = Capability()
            return
        }
        focus = Capability(
            supported: device.isFocusModeSupported(.locked) && device.isFocusModeSupported(.continuousAutoFocus),
            locked: device.focusMode == .locked
        )
        exposure = Capability(
            supported: device.isExposureModeSupported(.locked) && device.isExposureModeSupported(.continuousAutoExposure),
            locked: device.exposureMode == .locked
        )
        whiteBalance = Capability(
            supported: device.isWhiteBalanceModeSupported(.locked) && device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance),
            locked: device.whiteBalanceMode == .locked
        )
    }

    // MARK: Devices

    private func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        let previousName = selectedDevice?.localizedName
        devices = discovery.devices

        let stillConnected = devices.contains { $0.uniqueID == selectedDeviceID }
        let phone = devices.first(where: Self.isPhone)

        if stillConnected {
            if case .disconnected = status, let id = selectedDeviceID {
                // The same camera came back: rebuild the session with it.
                configureSession(deviceID: id, quietly: true)
            } else if let phone, selectedDevice.map(Self.isPhone) != true {
                // Prefer an iPhone when one appears.
                selectDevice(id: phone.uniqueID)
            }
        } else if let phone {
            selectDevice(id: phone.uniqueID)
        } else if selectedDeviceID != nil {
            // Wait for the camera to return rather than silently switching to the
            // webcam. The user can still pick another camera from the menu.
            status = .disconnected(previousName ?? "Camera")
            failInFlightCaptures()
        } else if let first = devices.first {
            selectDevice(id: first.uniqueID)
        } else {
            selectedDeviceID = nil
            status = .noCamera
            refreshCapabilities()
        }
    }

    private func observeDeviceChanges() {
        guard observers.isEmpty else { return }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            })
        }
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.didStopRunningNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleLostConnection() }
            })
        }
    }

    private func refreshEffectsWarning() {
        guard let device = selectedDevice else { effectsWarning = nil; return }
        var active: [String] = []
        if device.isCenterStageActive { active.append("Centre Stage") }
        if device.isPortraitEffectActive { active.append("Portrait") }
        if device.isStudioLightActive { active.append("Studio Light") }
        effectsWarning = active.isEmpty
            ? nil
            : "\(active.joined(separator: ", ")) is on. Turn it off in Control Centre > Video Effects."
    }

    private static func isPhone(_ device: AVCaptureDevice) -> Bool {
        device.deviceType == .continuityCamera || device.localizedName.localizedCaseInsensitiveContains("iPhone")
    }

    /// The format offering the largest stills, preferring higher video resolution on ties.
    private static func bestPhotoFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats.max { a, b in
            let pa = largestPhotoDimensions(in: a).map { Int($0.width) * Int($0.height) } ?? 0
            let pb = largestPhotoDimensions(in: b).map { Int($0.width) * Int($0.height) } ?? 0
            if pa != pb { return pa < pb }
            let va = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let vb = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(va.width) * Int(va.height) < Int(vb.width) * Int(vb.height)
        }
    }

    nonisolated private static func largestPhotoDimensions(in format: AVCaptureDevice.Format) -> CMVideoDimensions? {
        format.supportedMaxPhotoDimensions.max { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
    }
}

enum CameraError: LocalizedError {
    case notRunning
    case cannotUseDevice
    case noPhotoData
    case disconnected
    case timedOut
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: "The camera isn't running."
        case .cannotUseDevice: "This camera can't be used for capture."
        case .noPhotoData: "The camera returned no image."
        case .disconnected: "The camera disconnected before the photo was taken. Unlock your iPhone and try again."
        case .timedOut: "The camera didn't respond. Check your iPhone is unlocked and nearby, then try again."
        case .captureFailed(let reason): "The photo couldn't be taken: \(reason)"
        }
    }
}

/// Completes exactly once, whether from AVFoundation, a disconnect or a timeout.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Result<Data, Error>) -> Void)?

    init(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let completion = completion
        self.completion = nil
        lock.unlock()
        completion?(result)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            finish(.failure(error))
        } else if let data = photo.fileDataRepresentation() {
            finish(.success(data))
        } else {
            finish(.failure(CameraError.noPhotoData))
        }
    }
}
