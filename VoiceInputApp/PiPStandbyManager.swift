import AVKit
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit

@MainActor
protocol PiPControlling: AnyObject {
    var isPictureInPictureActive: Bool { get }
    var isPictureInPicturePossible: Bool { get }
    func startPictureInPicture()
    func stopPictureInPicture()
    func invalidatePlaybackState()
}

extension AVPictureInPictureController: PiPControlling {}

/// 用户主动开启的、具有真实产品信息的画中画待命面板。
///
/// 待命时麦克风保持关闭；只有键盘写入一个新会话后才开始录音。PiP 一旦被
/// 系统或用户关闭，会立即撤销 readiness，键盘下一次点击自动走冷启动路径。
@MainActor
final class PiPStandbyManager: NSObject, ObservableObject {
    enum State: Equatable {
        case unavailable
        case ready
        case starting
        case standby
        case recording(text: String)
        case processing(text: String)
        case failed(message: String)
    }

    static let shared = PiPStandbyManager()

    @Published private(set) var state: State = .unavailable
    @Published private(set) var isStartPossible = false

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: PiPControlling?
    private let supportProvider: () -> Bool
    private var possibleObservation: NSKeyValueObservation?
    private weak var hostView: UIView?
    private var frameTimer: Timer?
    private var startupWatchdog: Timer?
    private var recordingStartedAt: Date?
    private var lastText = ""
    private var lastPresentationTime = CMTime.zero

    override init() {
        supportProvider = {
            AVPictureInPictureController.isPictureInPictureSupported()
        }
        super.init()
    }

    init(controller: PiPControlling, isSupported: Bool) {
        self.controller = controller
        supportProvider = { isSupported }
        super.init()
        state = isSupported ? .ready : .unavailable
        isStartPossible = controller.isPictureInPicturePossible
    }

    var isActive: Bool { controller?.isPictureInPictureActive == true }
    var isSupported: Bool {
        supportProvider()
    }
    var canToggleStandby: Bool {
        isSupported
            && state != .starting
            && (isActive || isStartPossible)
    }

    func attach(to view: UIView) {
        if hostView === view, displayLayer.superlayer === view.layer {
            displayLayer.frame = view.bounds
            return
        }
        hostView = view
        displayLayer.removeFromSuperlayer()
        displayLayer.frame = view.bounds
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(displayLayer)

        if controller == nil, isSupported {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.canStartPictureInPictureAutomaticallyFromInline = false
            controller.requiresLinearPlayback = true
            self.controller = controller
            possibleObservation = controller.observe(
                \.isPictureInPicturePossible,
                options: [.initial, .new]
            ) { [weak self] controller, _ in
                let isPossible = controller.isPictureInPicturePossible
                Task { @MainActor [weak self] in
                    self?.updateStartAvailability(isPossible)
                }
            }
        }

        if isSupported, state == .unavailable {
            state = .ready
        }
        pushFrame()
    }

    func updateLayout() {
        guard let hostView else { return }
        displayLayer.frame = hostView.bounds
    }

    /// 必须由前台中的明确按钮点击调用。这里不请求麦克风，也不激活录音音频。
    func startStandby() {
        guard let controller else {
            failStartup(message: "画中画尚未准备好，请稍后重试")
            return
        }
        guard !controller.isPictureInPictureActive else {
            enterStandby()
            return
        }

        switch PiPLaunchPolicy.initialDecision(
            isSupported: isSupported,
            isPossible: controller.isPictureInPicturePossible
        ) {
        case .fail(.unsupported):
            failStartup(message: "此设备不支持画中画")
            return
        case .fail(.currentlyUnavailable):
            failStartup(message: "系统当前无法开启画中画，请关闭其他画中画后重试")
            return
        case .start:
            break
        }

        state = .starting
        startFrameTimer()
        pushFrame()
        controller.invalidatePlaybackState()

        // pushFrame 已同步提交可展示内容；紧接本次用户点击启动，失败会通过
        // delegate 变成明确错误，而不是假装已待命。
        controller.startPictureInPicture()
        scheduleStartupWatchdog()
    }

    func stopStandby() {
        controller?.stopPictureInPicture()
        leaveStandby()
        state = isSupported ? .ready : .unavailable
        pushFrame()
    }

    func setRecording(text: String = "") {
        recordingStartedAt = recordingStartedAt ?? Date()
        lastText = text
        state = .recording(text: text)
        publishReadinessForCurrentState()
        pushFrame()
    }

    func setProcessing(text: String = "") {
        lastText = text
        state = .processing(text: text)
        publishReadinessForCurrentState()
        pushFrame()
    }

    func returnToStandby() {
        recordingStartedAt = nil
        lastText = ""
        if isActive {
            enterStandby()
        } else {
            leaveStandby()
            state = isSupported ? .ready : .unavailable
        }
        pushFrame()
    }

    private func enterStandby() {
        cancelStartupWatchdog()
        recordingStartedAt = nil
        lastText = ""
        state = .standby
        startFrameTimer()
        publishReadinessForCurrentState()
        pushFrame()
    }

    private func leaveStandby() {
        cancelStartupWatchdog()
        frameTimer?.invalidate()
        frameTimer = nil
        recordingStartedAt = nil
        lastText = ""
        DarwinBridge.clearReadiness()
    }

    private func scheduleStartupWatchdog() {
        cancelStartupWatchdog()
        let startedAt = CFAbsoluteTimeGetCurrent()
        startupWatchdog = Timer.scheduledTimer(
            withTimeInterval: PiPLaunchPolicy.startupTimeout,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .starting else { return }
                self.handleStartupDeadline(
                    elapsed: CFAbsoluteTimeGetCurrent() - startedAt
                )
            }
        }
    }

    func handleStartupDeadline(elapsed: TimeInterval) {
        guard state == .starting else { return }
        if isActive {
            handleDidStart()
        } else if PiPLaunchPolicy.didStartupTimeOut(
            elapsed: elapsed,
            isActive: false
        ) {
            failStartup(
                message: "系统未启动画中画，请关闭其他画中画后重试"
            )
        }
    }

    private func cancelStartupWatchdog() {
        startupWatchdog?.invalidate()
        startupWatchdog = nil
    }

    private func failStartup(message: String) {
        leaveStandby()
        state = .failed(message: message)
        pushFrame()
    }

    func updateStartAvailability(_ isPossible: Bool) {
        isStartPossible = isPossible
        if isPossible, case .failed = state {
            state = .ready
            pushFrame()
        }
    }

    func handleDidStart() {
        enterStandby()
    }

    func handleFailedToStart(message: String) {
        failStartup(message: message)
    }

    func handleDidStop() {
        leaveStandby()
        state = isSupported ? .ready : .unavailable
        pushFrame()
    }

    private func startFrameTimer() {
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.publishReadinessForCurrentState()
                self?.pushFrame()
            }
        }
    }

    private func publishReadinessForCurrentState() {
        guard isActive else { return }
        switch state {
        case .standby:
            DarwinBridge.writeReadiness(.standby)
        case .recording:
            DarwinBridge.writeReadiness(.recording)
        case .processing:
            DarwinBridge.writeReadiness(.processing)
        default:
            break
        }
    }

    private func pushFrame() {
        guard displayLayer.status != .failed else {
            displayLayer.flush()
            return
        }
        let image = renderFrame()
        guard let sample = makeSampleBuffer(image: image) else { return }
        displayLayer.enqueue(sample)
    }

    private func renderFrame() -> UIImage {
        let size = CGSize(width: 640, height: 360)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [
                UIColor(red: 0.04, green: 0.07, blue: 0.14, alpha: 1).cgColor,
                UIColor(red: 0.08, green: 0.20, blue: 0.34, alpha: 1).cgColor
            ]
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: [0, 1]
            ) {
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }

            let title: String
            let subtitle: String
            let symbol: String
            let tint: UIColor
            switch state {
            case .unavailable:
                title = "画中画不可用"
                subtitle = "请检查系统设置"
                symbol = "exclamationmark.triangle.fill"
                tint = .systemOrange
            case .ready:
                title = "VoType 免切换语音"
                subtitle = isStartPossible
                    ? "点 App 内按钮开启 · 麦克风未开启"
                    : "系统画中画暂不可用"
                symbol = "mic.slash.circle.fill"
                tint = .systemBlue
            case .starting:
                title = "正在开启免切换语音"
                subtitle = "麦克风未开启"
                symbol = "ellipsis.circle.fill"
                tint = .systemBlue
            case .standby:
                title = "VoType 已待命"
                subtitle = "回到任意输入框，点实心麦克风即可说话"
                symbol = "mic.slash.circle.fill"
                tint = .systemBlue
            case .recording:
                title = elapsedRecordingTitle()
                subtitle = lastText.isEmpty ? "正在聆听 · 点键盘麦克风结束" : lastText
                symbol = "mic.circle.fill"
                tint = .systemRed
            case .processing:
                title = "正在整理文字"
                subtitle = lastText.isEmpty ? "完成后自动回填原输入框" : lastText
                symbol = "text.badge.checkmark"
                tint = .systemOrange
            case .failed(let message):
                title = "免切换语音未开启"
                subtitle = message
                symbol = "exclamationmark.triangle.fill"
                tint = .systemOrange
            }

            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 68, weight: .semibold)
            let symbolImage = UIImage(systemName: symbol, withConfiguration: symbolConfig)?
                .withTintColor(tint, renderingMode: .alwaysOriginal)
            symbolImage?.draw(in: CGRect(x: 286, y: 52, width: 68, height: 68))

            drawCentered(
                title,
                y: 145,
                font: .systemFont(ofSize: 29, weight: .bold),
                color: .white,
                canvasWidth: size.width
            )
            drawCentered(
                String(subtitle.prefix(56)),
                y: 205,
                font: .systemFont(ofSize: 18, weight: .medium),
                color: UIColor.white.withAlphaComponent(0.78),
                canvasWidth: size.width,
                maxWidth: 560
            )

            let privacyText: String
            if case .recording = state {
                privacyText = "麦克风使用中"
            } else {
                privacyText = "待命不录音"
            }
            drawCentered(
                privacyText,
                y: 300,
                font: .systemFont(ofSize: 15, weight: .semibold),
                color: tint,
                canvasWidth: size.width
            )
        }
    }

    private func elapsedRecordingTitle() -> String {
        let elapsed = max(0, Int(Date().timeIntervalSince(recordingStartedAt ?? Date())))
        return String(format: "正在聆听  %02d:%02d", elapsed / 60, elapsed % 60)
    }

    private func drawCentered(
        _ text: String,
        y: CGFloat,
        font: UIFont,
        color: UIColor,
        canvasWidth: CGFloat,
        maxWidth: CGFloat? = nil
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                style.lineBreakMode = .byTruncatingTail
                return style
            }()
        ]
        let width = maxWidth ?? canvasWidth
        (text as NSString).draw(
            in: CGRect(x: (canvasWidth - width) / 2, y: y, width: width, height: 48),
            withAttributes: attributes
        )
    }

    private func makeSampleBuffer(image: UIImage) -> CMSampleBuffer? {
        guard let cgImage = image.cgImage else { return nil }
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            cgImage.width,
            cgImage.height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }

        lastPresentationTime = lastPresentationTime + CMTime(value: 1, timescale: 2)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 2),
            presentationTimeStamp: lastPresentationTime,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        return sample
    }
}

extension PiPStandbyManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool { false }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        Task { @MainActor in self.pushFrame() }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

extension PiPStandbyManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in self.handleDidStart() }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            self.handleFailedToStart(message: error.localizedDescription)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in self.handleDidStop() }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

struct PiPStandbySourceView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        PiPStandbyManager.shared.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        PiPStandbyManager.shared.attach(to: uiView)
        DispatchQueue.main.async {
            PiPStandbyManager.shared.updateLayout()
        }
    }
}
