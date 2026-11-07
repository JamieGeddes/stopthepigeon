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
    private var effectsTimer: Timer?

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
        effectsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshEffectsWarning() }
        }
    }

    func selectDevice(id: String) {
        guard let device = devices.first(where: { $0.uniqueID == id }) else { return }
        selectedDeviceID = id
        status = .starting

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

                if let largest = Self.largestPhotoDimensions(in: device.activeFormat) {
                    photoOutput.maxPhotoDimensions = largest
                }
                if !session.isRunning { session.startRunning() }

                let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                let photo = photoOutput.maxPhotoDimensions
                Task { @MainActor in
                    self.videoAspect = dims.height > 0 ? Double(dims.width) / Double(dims.height) : 4.0 / 3.0
                    self.photoSizeDescription = "\(photo.width) × \(photo.height)"
                    self.status = .running
                    self.refreshCapabilities()
                    self.refreshEffectsWarning()
                }
            } catch {
                session.commitConfiguration()
                Task { @MainActor in self.status = .failed(error.localizedDescription) }
            }
        }
    }

    /// Captures a still and returns its encoded data plus a file extension.
    func capturePhoto() async throws -> (data: Data, fileExtension: String) {
        guard status == .running else { throw CameraError.notRunning }

        let useJPEG = photoOutput.availablePhotoCodecTypes.contains(.jpeg)
        let settings = useJPEG
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            : AVCapturePhotoSettings()
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let delegate = PhotoCaptureDelegate { [weak self] result in
                Task { @MainActor in self?.inFlightCaptures[settings.uniqueID] = nil }
                continuation.resume(with: result)
            }
            inFlightCaptures[settings.uniqueID] = delegate
            let photoOutput = photoOutput
            sessionQueue.async { photoOutput.capturePhoto(with: settings, delegate: delegate) }
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
        devices = discovery.devices

        let stillConnected = devices.contains { $0.uniqueID == selectedDeviceID }
        let preferred = devices.first(where: Self.isPhone) ?? devices.first
        // Switch to an iPhone when one appears, or recover when the current camera goes away.
        if !stillConnected || (preferred.map(Self.isPhone) == true && selectedDevice.map(Self.isPhone) != true) {
            if let preferred {
                selectDevice(id: preferred.uniqueID)
            } else {
                selectedDeviceID = nil
                status = .noCamera
                refreshCapabilities()
            }
        }
    }

    private func observeDeviceChanges() {
        guard observers.isEmpty else { return }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
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

    var errorDescription: String? {
        switch self {
        case .notRunning: "The camera isn't running."
        case .cannotUseDevice: "This camera can't be used for capture."
        case .noPhotoData: "The camera returned no image."
        }
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: (Result<Data, Error>) -> Void

    init(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            completion(.failure(error))
        } else if let data = photo.fileDataRepresentation() {
            completion(.success(data))
        } else {
            completion(.failure(CameraError.noPhotoData))
        }
    }
}
