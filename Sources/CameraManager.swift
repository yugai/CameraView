//
//  CameraManager.swift of MijickCameraView
//
//  Created by Tomasz Kurylik
//    - Twitter: https://twitter.com/tkurylik
//    - Mail: tomasz.kurylik@mijick.com
//    - GitHub: https://github.com/FulcrumOne
//
//  Copyright ©2024 Mijick. Licensed under MIT License.


import SwiftUI
import AVKit
import CoreMotion
import MijickTimer

public class CameraManager: NSObject, ObservableObject {
    // MARK: Attributes
    @Published private(set) var outputType: CameraOutputType
    @Published private(set) var cameraPosition: AVCaptureDevice.Position
    @Published private(set) var zoomFactor: CGFloat
    @Published private(set) var flashMode: AVCaptureDevice.FlashMode
    @Published private(set) var torchMode: AVCaptureDevice.TorchMode
    @Published private(set) var mirrorOutput: Bool
    @Published private(set) var isGridVisible: Bool
    @Published private(set) var isRecording: Bool
    @Published private(set) var recordingTime: MTime
    @Published private(set) var deviceOrientation: AVCaptureVideoOrientation

    // MARK: Devices
    private var frontCamera: AVCaptureDevice?
    private var backCamera: AVCaptureDevice?
    private var microphone: AVCaptureDevice?

    // MARK: Input
    private var captureSession: AVCaptureSession!
    private var frontCameraInput: AVCaptureDeviceInput?
    private var backCameraInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    // MARK: Output
    private var photoOutput: AVCapturePhotoOutput?
    private var videoOutput: AVCaptureMovieFileOutput?

    // MARK: Completions
    private var onMediaCaptured: ((Result<MCameraMedia, CameraManager.Error>) -> ())?

    // MARK: UI Elements
    private(set) var cameraLayer: AVCaptureVideoPreviewLayer!
    private(set) var cameraGridView: GridView!
    private(set) var cameraFocusView: UIImageView!
    private(set) var cameraBlurView: UIImageView!

    // MARK: Others
    private var lastAction: LastAction = .none
    private var timer: MTimer = .createNewInstance()
    private var motionManager: CMMotionManager = .init()


    // MARK: Initialiser
    public init(config: CameraManagerConfig) {
        self.outputType = config.outputType
        self.cameraPosition = config.cameraPosition
        self.zoomFactor = config.zoomFactor
        self.flashMode = config.flashMode
        self.torchMode = config.torchMode
        self.mirrorOutput = config.mirrorOutput
        self.isGridVisible = config.gridVisible
        self.isRecording = false
        self.recordingTime = .zero
        self.deviceOrientation = .portrait

        self.cameraFocusView = .init(image: config.focusImage)
        self.cameraFocusView.tintColor = config.focusImageColor
        self.cameraFocusView.frame.size = .init(width: config.focusImageSize, height: config.focusImageSize)
    }
}

// MARK: - Initialising Camera
extension CameraManager {
    func setup(in cameraView: UIView) throws {
        initialiseCaptureSession()
        initialiseCameraLayer(cameraView)
        initialiseCameraGridView()
        initialiseDevices()
        initialiseInputs()
        initialiseOutputs()
        initializeMotionManager()
        initialiseObservers()

        try setupDeviceInputs()
        try setupDeviceOutput()
        try setupFrameRecorder()

        startCaptureSession()
        announceSetupCompletion()
    }
}
private extension CameraManager {
    func initialiseCaptureSession() {
        captureSession = .init()
    }
    func initialiseCameraLayer(_ cameraView: UIView) {
        cameraLayer = .init(session: captureSession)
        cameraLayer.videoGravity = .resizeAspectFill
        
        cameraView.layer.addSublayer(cameraLayer)
    }
    func initialiseCameraGridView() {
        cameraGridView = .init()
        cameraGridView.addAsSubview(to: cameraView)
        cameraGridView.alpha = isGridVisible ? 1 : 0
    }
    func initialiseDevices() {
        frontCamera = .default(.builtInWideAngleCamera, for: .video, position: .front)
        backCamera = .default(for: .video)
        microphone = .default(for: .audio)
    }
    func initialiseInputs() {
        frontCameraInput = .init(frontCamera)
        backCameraInput = .init(backCamera)
        audioInput = .init(microphone)
    }
    func initialiseOutputs() {
        photoOutput = .init()
        videoOutput = .init()
    }
    func initializeMotionManager() {
        motionManager.accelerometerUpdateInterval = 1
        motionManager.gyroUpdateInterval = 1
        motionManager.startAccelerometerUpdates(to: OperationQueue.current ?? .init(), withHandler: handleAccelerometerUpdates)
    }
    func initialiseObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleSessionWasInterrupted), name: .AVCaptureSessionWasInterrupted, object: captureSession)
    }
    func setupDeviceInputs() throws {
        try setupCameraInput(cameraPosition)
        try setupInput(audioInput)
    }
    func setupDeviceOutput() throws {
        try setupCameraOutput(outputType)
    }
    func setupFrameRecorder() throws {
        let captureVideoOutput = AVCaptureVideoDataOutput()
        captureVideoOutput.setSampleBufferDelegate(self, queue: DispatchQueue.main)

        if captureSession.canAddOutput(captureVideoOutput) { captureSession?.addOutput(captureVideoOutput) }
    }
    func startCaptureSession() { DispatchQueue(label: "cameraSession").async { [self] in
        captureSession.startRunning()
    }}
    func announceSetupCompletion() { DispatchQueue.main.async { [self] in
        objectWillChange.send()
    }}
}
private extension CameraManager {
    func setupCameraInput(_ cameraPosition: AVCaptureDevice.Position) throws { switch cameraPosition {
        case .front: try setupInput(frontCameraInput)
        default: try setupInput(backCameraInput)
    }}
    func setupCameraOutput(_ outputType: CameraOutputType) throws { if let output = getOutput(outputType) {
        try setupOutput(output)
    }}
}
private extension CameraManager {
    func setupInput(_ input: AVCaptureDeviceInput?) throws {
        guard let input,
              captureSession.canAddInput(input)
        else { throw Error.cannotSetupInput }

        captureSession.addInput(input)
    }
    func setupOutput(_ output: AVCaptureOutput?) throws {
        guard let output,
              captureSession.canAddOutput(output)
        else { throw Error.cannotSetupOutput }

        captureSession.addOutput(output)
    }
}

// MARK: - Checking Camera Permissions
extension CameraManager {
    func checkPermissions() throws {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied { throw Error.microphonePermissionsNotGranted }
        if AVCaptureDevice.authorizationStatus(for: .video) == .denied { throw Error.cameraPermissionsNotGranted }
    }
}

// MARK: - On Media Captured
extension CameraManager {
    func onMediaCaptured(_ completionHandler: @escaping (Result<MCameraMedia, CameraManager.Error>) -> ()) {
        onMediaCaptured = completionHandler
    }
}

// MARK: - Changing Output Type
extension CameraManager {
    func changeOutputType(_ newOutputType: CameraOutputType) throws { if newOutputType != outputType && !isChanging {
        captureCurrentFrameAndDelay(.outputTypeChange) { [self] in
            removeCameraOutput(outputType)
            try setupCameraOutput(newOutputType)
            updateCameraOutputType(newOutputType)

            updateTorchMode(.off)
            removeBlur()
        }
    }}
}
private extension CameraManager {
    func removeCameraOutput(_ outputType: CameraOutputType) { if let output = getOutput(outputType) {
        captureSession.removeOutput(output)
    }}
    func updateCameraOutputType(_ cameraOutputType: CameraOutputType) {
        outputType = cameraOutputType
    }
}
private extension CameraManager {
    func getOutput(_ outputType: CameraOutputType) -> AVCaptureOutput? { switch outputType {
        case .photo: photoOutput
        case .video: videoOutput
    }}
}

// MARK: - Changing Camera Position
extension CameraManager {
    func changeCamera(_ newPosition: AVCaptureDevice.Position) throws { if newPosition != cameraPosition && !isChanging {
        captureCurrentFrameAndDelay(.cameraPositionChange) { [self] in
            removeCameraInput(cameraPosition)
            try setupCameraInput(newPosition)
            updateCameraPosition(newPosition)
            
            updateTorchMode(.off)
            removeBlur()
        }
    }}
}
private extension CameraManager {
    func removeCameraInput(_ position: AVCaptureDevice.Position) { if let input = getInput(position) {
        captureSession.removeInput(input)
    }}
    func updateCameraPosition(_ position: AVCaptureDevice.Position) {
        cameraPosition = position
    }
}
private extension CameraManager {
    func getInput(_ position: AVCaptureDevice.Position) -> AVCaptureInput? { switch position {
        case .front: frontCameraInput
        default: backCameraInput
    }}
}

// MARK: - Camera Focusing
extension CameraManager {
    func setCameraFocus(_ touchPoint: CGPoint) throws { if let device = getDevice(cameraPosition) {
        insertNewCameraFocusView(touchPoint)
        animateCameraFocusView()

        try setCameraFocus(touchPoint, device)
    }}
}
private extension CameraManager {
    func insertNewCameraFocusView(_ touchPoint: CGPoint) {
        cameraFocusView.frame.origin.x = touchPoint.x - cameraFocusView.frame.size.width / 2
        cameraFocusView.frame.origin.y = touchPoint.y - cameraFocusView.frame.size.height / 2
        cameraFocusView.transform = .init(scaleX: 0, y: 0)
        cameraFocusView.alpha = 1

        cameraView.addSubview(cameraFocusView)
    }
    func animateCameraFocusView() {
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0) { [self] in cameraFocusView.transform = .init(scaleX: 1, y: 1) }
        UIView.animate(withDuration: 0.5, delay: 1.5) { [self] in cameraFocusView.alpha = 0.2 } completion: { _ in
            UIView.animate(withDuration: 0.5, delay: 3.5) { [self] in cameraFocusView.alpha = 0 }
        }
    }
    func setCameraFocus(_ touchPoint: CGPoint, _ device: AVCaptureDevice) throws {
        let focusPoint = cameraLayer.captureDevicePointConverted(fromLayerPoint: touchPoint)
        try configureCameraFocus(focusPoint, device)
    }
}
private extension CameraManager {
    func configureCameraFocus(_ focusPoint: CGPoint, _ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        setFocusPointOfInterest(focusPoint, device)
        setExposurePointOfInterest(focusPoint, device)
        device.unlockForConfiguration()
    }
}
private extension CameraManager {
    func setFocusPointOfInterest(_ focusPoint: CGPoint, _ device: AVCaptureDevice) { if device.isFocusPointOfInterestSupported {
        device.focusPointOfInterest = focusPoint
        device.focusMode = .autoFocus
    }}
    func setExposurePointOfInterest(_ focusPoint: CGPoint, _ device: AVCaptureDevice) { if device.isExposurePointOfInterestSupported {
        device.exposurePointOfInterest = focusPoint
        device.exposureMode = .autoExpose
    }}
}

// MARK: - Changing Zoom Factor
extension CameraManager {
    func changeZoomFactor(_ value: CGFloat) throws { if let device = getDevice(cameraPosition), !isChanging {
        let zoomFactor = calculateZoomFactor(value, device)

        try setVideoZoomFactor(zoomFactor, device)
        updateZoomFactor(zoomFactor)
    }}
}
private extension CameraManager {
    func getDevice(_ position: AVCaptureDevice.Position) -> AVCaptureDevice? { switch position {
        case .front: frontCamera
        default: backCamera
    }}
    func calculateZoomFactor(_ value: CGFloat, _ device: AVCaptureDevice) -> CGFloat {
        min(max(value, getMinZoomLevel(device)), getMaxZoomLevel(device))
    }
    func setVideoZoomFactor(_ zoomFactor: CGFloat, _ device: AVCaptureDevice) throws  {
        try device.lockForConfiguration()
        device.videoZoomFactor = zoomFactor
        device.unlockForConfiguration()
    }
    func updateZoomFactor(_ value: CGFloat) {
        zoomFactor = value
    }
}
private extension CameraManager {
    func getMinZoomLevel(_ device: AVCaptureDevice) -> CGFloat {
        device.minAvailableVideoZoomFactor
    }
    func getMaxZoomLevel(_ device: AVCaptureDevice) -> CGFloat {
        min(device.maxAvailableVideoZoomFactor, 3)
    }
}

// MARK: - Changing Flash Mode
extension CameraManager {
    func changeFlashMode(_ mode: AVCaptureDevice.FlashMode) throws { if let device = getDevice(cameraPosition), device.hasFlash, !isChanging {
        updateFlashMode(mode)
    }}
}
private extension CameraManager {
    func updateFlashMode(_ value: AVCaptureDevice.FlashMode) {
        flashMode = value
    }
}

// MARK: - Changing Torch Mode
extension CameraManager {
    func changeTorchMode(_ mode: AVCaptureDevice.TorchMode) throws { if let device = getDevice(cameraPosition), device.hasTorch, !isChanging {
        try changeTorchMode(device, mode)
        updateTorchMode(mode)
    }}
}
private extension CameraManager {
    func changeTorchMode(_ device: AVCaptureDevice, _ mode: AVCaptureDevice.TorchMode) throws {
        try device.lockForConfiguration()
        device.torchMode = mode
        device.unlockForConfiguration()
    }
    func updateTorchMode(_ value: AVCaptureDevice.TorchMode) {
        torchMode = value
    }
}

// MARK: - Changing Mirror Mode
extension CameraManager {
    func changeMirrorMode(_ shouldMirror: Bool) { if !isChanging {
        mirrorOutput = shouldMirror
    }}
}

// MARK: - Changing Grid Mode
extension CameraManager {
    func changeGridVisibility(_ shouldShowGrid: Bool) { if !isChanging {
        animateGridVisibilityChange(shouldShowGrid)
        updateGridVisibility(shouldShowGrid)
    }}
}
private extension CameraManager {
    func animateGridVisibilityChange(_ shouldShowGrid: Bool) { UIView.animate(withDuration: 0.32) { [self] in
        cameraGridView.alpha = shouldShowGrid ? 1 : 0
    }}
    func updateGridVisibility(_ shouldShowGrid: Bool) {
        isGridVisible = shouldShowGrid
    }
}

// MARK: - Capturing Output
extension CameraManager {
    func captureOutput() { if !isChanging { switch outputType {
        case .photo: capturePhoto()
        case .video: toggleVideoRecording()
    }}}
}

// MARK: Photo
private extension CameraManager {
    func capturePhoto() {
        let settings = getPhotoOutputSettings()

        configureOutput(photoOutput)
        photoOutput?.capturePhoto(with: settings, delegate: self)
        performCaptureAnimation()
    }
}
private extension CameraManager {
    func getPhotoOutputSettings() -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings()
        settings.flashMode = flashMode
        return settings
    }
    func performCaptureAnimation() {
        let view = createCaptureAnimationView()
        cameraView.addSubview(view)

        animateCaptureView(view)
    }
}
private extension CameraManager {
    func createCaptureAnimationView() -> UIView {
        let view = UIView()
        view.frame = cameraView.frame
        view.backgroundColor = .black
        view.alpha = 0
        return view
    }
    func animateCaptureView(_ view: UIView) {
        UIView.animate(withDuration: captureAnimationDuration) { view.alpha = 1 }
        UIView.animate(withDuration: captureAnimationDuration, delay: captureAnimationDuration) { view.alpha = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2 * captureAnimationDuration) { view.removeFromSuperview() }
    }
}
private extension CameraManager {
    var captureAnimationDuration: Double { 0.1 }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Swift.Error)?) {
        if let media = createPhotoMedia(photo) { onMediaCaptured?(.success(media)) }
        else { onMediaCaptured?(.failure(.capturedPhotoCannotBeFetched)) }
    }
}
private extension CameraManager {
    func createPhotoMedia(_ photo: AVCapturePhoto) -> MCameraMedia? {
        guard let imageData = photo.fileDataRepresentation() else { return nil }
        return .init(data: imageData, url: nil)
    }
}

// MARK: Video
private extension CameraManager {
    func toggleVideoRecording() { switch videoOutput?.isRecording {
        case false: startRecording()
        default: stopRecording()
    }}
}
private extension CameraManager {
    func startRecording() {
        let url = prepareUrlForVideoRecording()

        configureOutput(videoOutput)
        videoOutput?.startRecording(to: url, recordingDelegate: self)
        updateIsRecording(true)
        startRecordingTimer()
    }
    func stopRecording() {
        videoOutput?.stopRecording()
        updateIsRecording(false)
        stopRecordingTimer()
    }
}
private extension CameraManager {
    func prepareUrlForVideoRecording() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let fileUrl = paths[0].appendingPathComponent("output.mp4")

        try? FileManager.default.removeItem(at: fileUrl)
        return fileUrl
    }
    func updateIsRecording(_ value: Bool) {
        isRecording = value
    }
    func startRecordingTimer() {
        try? timer
            .publish(every: 1) { [self] in recordingTime = $0 }
            .start()
    }
    func stopRecordingTimer() {
        timer.reset()
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: (any Swift.Error)?) {
        let media = MCameraMedia(data: nil, url: outputFileURL)
        onMediaCaptured?(.success(media))
    }
}

// MARK: - Handling Device Rotation
private extension CameraManager {
    func handleAccelerometerUpdates(_ data: CMAccelerometerData?, _ error: Swift.Error?) { if let data, error == nil {
        let newDeviceOrientation = fetchDeviceOrientation(data.acceleration)
        deviceOrientation = newDeviceOrientation
    }}
}
private extension CameraManager {
    func fetchDeviceOrientation(_ acceleration: CMAcceleration) -> AVCaptureVideoOrientation { switch acceleration {
        case let acceleration where acceleration.x >= 0.75: return .landscapeLeft
        case let acceleration where acceleration.x <= -0.75: return .landscapeRight
        case let acceleration where acceleration.y <= -0.75: return .portrait
        case let acceleration where acceleration.y >= 0.75: return .portraitUpsideDown
        default: return deviceOrientation
    }}
}

// MARK: - Handling Observers
private extension CameraManager {
    @objc func handleSessionWasInterrupted() {
        torchMode = .off
        updateIsRecording(false)
        stopRecordingTimer()
    }
}

// MARK: - Output Type / Camera Change Animations
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { if lastAction != .none {
        let snapshot = createSnapshot(sampleBuffer)

        insertBlurView(snapshot)
        animateBlurFlip()
        lastAction = .none
    }}
}
private extension CameraManager {
    func createSnapshot(_ sampleBuffer: CMSampleBuffer?) -> UIImage? {
        guard let sampleBuffer,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return nil }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let image = UIImage(ciImage: ciImage, scale: UIScreen.main.scale, orientation: blurImageOrientation)
        return image
    }
    func insertBlurView(_ snapshot: UIImage?) { if let snapshot {
        cameraBlurView = UIImageView(image: snapshot)
        cameraBlurView.frame = cameraView.frame
        cameraBlurView.contentMode = .scaleAspectFill
        cameraBlurView.clipsToBounds = true
        cameraBlurView.applyBlurEffect(style: .regular, animationDuration: blurAnimationDuration)

        cameraView.addSubview(cameraBlurView)
    }}
    func animateBlurFlip() { if lastAction == .cameraPositionChange {
        UIView.transition(with: cameraView, duration: flipAnimationDuration, options: flipAnimationTransition) {}
    }}
    func removeBlur() { Task { @MainActor [self] in
        try await Task.sleep(nanoseconds: 100_000_000)
        UIView.animate(withDuration: blurAnimationDuration) { self.cameraBlurView.alpha = 0 }
    }}
}
private extension CameraManager {
    var blurImageOrientation: UIImage.Orientation { cameraPosition == .back ? .right : .leftMirrored }
    var blurAnimationDuration: Double { 0.3 }

    var flipAnimationDuration: Double { 0.44 }
    var flipAnimationTransition: UIView.AnimationOptions { cameraPosition == .back ? .transitionFlipFromLeft : .transitionFlipFromRight }
}
private extension CameraManager {
    enum LastAction { case cameraPositionChange, outputTypeChange, mediaCapture, none }
}

// MARK: - Modifiers
extension CameraManager {
    var hasFlash: Bool { getDevice(cameraPosition)?.hasFlash ?? false }
    var hasTorch: Bool { getDevice(cameraPosition)?.hasTorch ?? false }
}

// MARK: - Helpers
private extension CameraManager {
    func captureCurrentFrameAndDelay(_ type: LastAction, _ action: @escaping () throws -> ()) { Task { @MainActor in
        lastAction = type
        try await Task.sleep(nanoseconds: 150_000_000)

        try action()
    }}
    func configureOutput(_ output: AVCaptureOutput?) { if let connection = output?.connection(with: .video), connection.isVideoMirroringSupported {
        connection.isVideoMirrored = mirrorOutput ? cameraPosition != .front : cameraPosition == .front
        connection.videoOrientation = deviceOrientation
    }}
}
private extension CameraManager {
    var cameraView: UIView { cameraLayer.superview ?? .init() }
    var isChanging: Bool { (cameraBlurView?.alpha ?? 0) > 0 }
}


// MARK: - Errors
public extension CameraManager { enum Error: Swift.Error {
    case microphonePermissionsNotGranted, cameraPermissionsNotGranted
    case cannotSetupInput, cannotSetupOutput, capturedPhotoCannotBeFetched
}}