import AVKit
import UIKit
import CoreMedia
import CoreVideo

/// 画中画管理器
/// 使用 AVSampleBufferDisplayLayer + AVPictureInPictureController 创建悬浮窗
/// 让容器 App 在用户滑回宿主 App 后继续在后台录音
/// Typeless 和微信输入法用的就是这套方案
class PiPManager: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {

    static let shared = PiPManager()

    // MARK: - 依赖

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private weak var hostView: UIView?
    private var frameTimer: DispatchSourceTimer?
    private let frameQueue = DispatchQueue(label: "com.daseanle.votype.pipframes", qos: .userInitiated)
    private var recordingStartTime: Date?
    private var liveText: String = ""
    private var isSetupComplete = false

    // PiP 显示状态
    enum DisplayState {
        case standby       // 待命中 (PiP保活)
        case recording     // 正在录音
        case completed     // 完成 (短暂显示后回到 standby)
    }
    private var displayState: DisplayState = .standby

    // 用于线程安全的锁
    private let stateLock = NSLock()

    // MARK: - 状态

    var isPiPActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pipController?.isPictureInPictureActive ?? false
    }

    var canStartPiP: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    // MARK: - 初始化

    /// 在指定 view 上设置 PiP 显示层
    /// 必须在 view 已添加到 window 后调用
    /// 幂等:如果已 setup 过,只把 layer 重新挂载到新 view
    func setup(in view: UIView) {
        guard view.window != nil else {
            // view 还没挂到 window 上,延迟重试
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.setup(in: view)
            }
            return
        }

        stateLock.lock()

        // 幂等:已 setup 过,只把现有 layer 挂到新 view
        if isSetupComplete, let existingLayer = displayLayer {
            existingLayer.removeFromSuperlayer()
            existingLayer.frame = view.bounds
            view.layer.insertSublayer(existingLayer, at: 0)
            hostView = view
            stateLock.unlock()
            print("[PiP] Re-hosted existing layer to new view")
            pushFrame()
            return
        }

        // 首次 setup
        hostView = view

        let layer = AVSampleBufferDisplayLayer()
        layer.frame = view.bounds
        layer.backgroundColor = UIColor.black.cgColor
        view.layer.insertSublayer(layer, at: 0)
        displayLayer = layer

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        pipController = controller

        isSetupComplete = true
        print("[PiP] Setup complete, layer status: \(layer.status.rawValue)")

        stateLock.unlock()

        for _ in 0..<3 {
            pushFrame()
        }
    }

    // MARK: - 状态切换 (供 BackgroundDictationManager 调用)

    /// 设置为待命状态
    func setStandbyMode() {
        stateLock.lock()
        displayState = .standby
        recordingStartTime = nil
        liveText = ""
        stateLock.unlock()
        startFrameTimer()
        pushFrame()
        print("[PiP] State -> standby")
    }

    /// 设置为录音状态
    func setRecordingMode() {
        stateLock.lock()
        displayState = .recording
        recordingStartTime = Date()
        liveText = ""
        stateLock.unlock()
        print("[PiP] State -> recording")
    }

    /// 设置为完成状态
    func setCompletedMode(text: String) {
        stateLock.lock()
        displayState = .completed
        liveText = text
        stateLock.unlock()
        pushFrame()
        print("[PiP] State -> completed")
    }

    // MARK: - 开始 / 停止 PiP

    func startPiP() {
        stateLock.lock()
        guard let controller = pipController, isSetupComplete else {
            stateLock.unlock()
            print("[PiP] Not ready, retrying in 0.5s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startPiP()
            }
            return
        }
        stateLock.unlock()

        // 确保画面在持续推送
        startFrameTimer()

        // 设置录音开始时间
        stateLock.lock()
        recordingStartTime = Date()
        stateLock.unlock()

        // 尝试启动 PiP
        // 注意:在前台调用 startPictureInPicture 可能不会立即生效
        // 但 canStartPictureInPictureAutomaticallyFromInline = true 会在进入后台时自动启动
        if !controller.isPictureInPictureActive {
            controller.startPictureInPicture()
            print("[PiP] startPictureInPicture() called")
        }
    }

    func stopPiP() {
        stopFrameTimer()

        stateLock.lock()
        recordingStartTime = nil
        stateLock.unlock()

        // 推送最后一帧 (完成状态)
        pushFrame(isFinal: true)

        // 通知 PiP 控制器状态已变更
        stateLock.lock()
        let controller = pipController
        stateLock.unlock()
        controller?.invalidatePlaybackState()

        // 延迟停止 PiP,让用户看到完成画面
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.stateLock.lock()
            let ctrl = self?.pipController
            self?.stateLock.unlock()
            ctrl?.stopPictureInPicture()
            print("[PiP] stopPictureInPicture() called")
        }
    }

    /// 更新悬浮窗中显示的实时识别文本
    func updateLiveText(_ text: String) {
        stateLock.lock()
        liveText = text
        stateLock.unlock()

        // 在后台线程生成画面,避免阻塞主线程
        frameQueue.async { [weak self] in
            self?.pushFrame()
        }
    }

    // MARK: - 帧定时器 (使用 DispatchSourceTimer,后台也能可靠触发)

    private func startFrameTimer() {
        frameTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: frameQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.pushFrame()
        }
        timer.resume()
        frameTimer = timer
    }

    private func stopFrameTimer() {
        frameTimer?.cancel()
        frameTimer = nil
    }

    // MARK: - 画面生成

    private func pushFrame(isFinal: Bool = false) {
        stateLock.lock()
        guard let layer = displayLayer else {
            stateLock.unlock()
            return
        }

        // 检查 layer 状态,如果 failed 则 flush 后继续
        if layer.status == .failed {
            print("[PiP] Layer status failed, flushing...")
            layer.flush()
        }

        let currentLiveText = liveText
        let currentStartTime = recordingStartTime
        stateLock.unlock()

        // 在后台线程生成图片 (线程安全)
        let image = generateRecordingImage(isFinal: isFinal, liveText: currentLiveText, startTime: currentStartTime)
        guard let buffer = createSampleBuffer(from: image) else {
            print("[PiP] Failed to create sample buffer")
            return
        }

        // enqueue 必须在主线程
        DispatchQueue.main.async { [weak self] in
            self?.stateLock.lock()
            let layerToEnqueue = self?.displayLayer
            self?.stateLock.unlock()
            layerToEnqueue?.enqueue(buffer)
        }
    }

    /// 生成画面 (根据 displayState 选择不同画面)
    private func generateRecordingImage(isFinal: Bool, liveText: String, startTime: Date?) -> UIImage {
        let size = CGSize(width: 640, height: 360)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { ctx in
            // 背景:深色渐变
            let colors = [
                UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1).cgColor,
                UIColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1).cgColor
            ]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

            let currentDisplayState: DisplayState = {
                stateLock.lock()
                defer { stateLock.unlock() }
                return displayState
            }()

            switch currentDisplayState {
            case .standby:
                drawStandbyImage(ctx: ctx, size: size)
            case .recording:
                drawRecordingImage(ctx: ctx, size: size, liveText: liveText, startTime: startTime)
            case .completed:
                drawCompletedImage(ctx: ctx, size: size, liveText: liveText)
            }
        }
    }

    // MARK: - 待命画面

    private func drawStandbyImage(ctx: UIGraphicsImageRendererContext, size: CGSize) {
        // 麦克风图标 (蓝色,表示待命)
        let micConfig = UIImage.SymbolConfiguration(pointSize: 50, weight: .medium)
        let micImage = UIImage(systemName: "mic.circle", withConfiguration: micConfig)
        micImage?.withTintColor(.systemBlue).draw(in: CGRect(x: 295, y: 70, width: 50, height: 50))

        // "VoType 待命中"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let text = "VoType 待命中"
        let textSize = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: CGPoint(x: (size.width - textSize.width) / 2, y: 140),
            withAttributes: attrs
        )

        // 副标题
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: UIColor.lightGray
        ]
        let subText = "在键盘上点麦克风即可说话"
        let subSize = (subText as NSString).size(withAttributes: subAttrs)
        (subText as NSString).draw(
            at: CGPoint(x: (size.width - subSize.width) / 2, y: 180),
            withAttributes: subAttrs
        )

        // 脉冲圆环动画
        let phase = Date().timeIntervalSince1970 * 2
        let alpha = 0.3 + 0.2 * (sin(phase) * 0.5 + 0.5)
        let ringColor = UIColor.systemBlue.withAlphaComponent(alpha)
        let ringPath = UIBezierPath(ovalIn: CGRect(x: 275, y: 50, width: 90, height: 90))
        ringColor.setStroke()
        ringPath.lineWidth = 3
        ringPath.stroke()
    }

    // MARK: - 录音画面

    private func drawRecordingImage(ctx: UIGraphicsImageRendererContext, size: CGSize, liveText: String, startTime: Date?) {
        // 麦克风图标 (红色)
        let micConfig = UIImage.SymbolConfiguration(pointSize: 60, weight: .bold)
        let micImage = UIImage(systemName: "mic.fill", withConfiguration: micConfig)
        micImage?.withTintColor(.systemRed).draw(in: CGRect(x: 290, y: 60, width: 60, height: 60))

        // 录音时长
        var duration = ""
        if let start = startTime {
            let elapsed = Int(Date().timeIntervalSince(start))
            let mins = elapsed / 60
            let secs = elapsed % 60
            duration = String(format: "%02d:%02d", mins, secs)
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 36, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        let textSize = (duration as NSString).size(withAttributes: attrs)
        (duration as NSString).draw(
            at: CGPoint(x: (size.width - textSize.width) / 2, y: 140),
            withAttributes: attrs
        )

        // 副标题
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 20),
            .foregroundColor: UIColor.lightGray
        ]
        let subText = "正在聆听..."
        let subSize = (subText as NSString).size(withAttributes: subAttrs)
        (subText as NSString).draw(
            at: CGPoint(x: (size.width - subSize.width) / 2, y: 200),
            withAttributes: subAttrs
        )

        // 实时识别文本
        if !liveText.isEmpty {
            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 18),
                .foregroundColor: UIColor.white
            ]
            let displayText = String(liveText.prefix(60))
            let rect = CGRect(x: 40, y: 235, width: size.width - 80, height: 60)
            (displayText as NSString).draw(in: rect, withAttributes: textAttrs)
        }

        // 波形动画
        let wavePath = UIBezierPath()
        let waveY: CGFloat = 280
        let waveWidth: CGFloat = 400
        let waveX: CGFloat = (size.width - waveWidth) / 2
        let phase = Date().timeIntervalSince1970 * 3

        wavePath.move(to: CGPoint(x: waveX, y: waveY))
        for i in 0...Int(waveWidth) {
            let x = waveX + CGFloat(i)
            let relX = CGFloat(i) / waveWidth
            let amp = 25 * sin(relX * .pi * 6 + phase) * (0.5 + 0.5 * sin(phase + relX * .pi * 2))
            wavePath.addLine(to: CGPoint(x: x, y: waveY + amp))
        }
        UIColor.systemBlue.setStroke()
        wavePath.lineWidth = 3
        wavePath.lineCapStyle = .round
        wavePath.stroke()
    }

    // MARK: - 完成画面

    private func drawCompletedImage(ctx: UIGraphicsImageRendererContext, size: CGSize, liveText: String) {
        // 完成图标
        let checkConfig = UIImage.SymbolConfiguration(pointSize: 80, weight: .bold)
        let checkImage = UIImage(systemName: "checkmark.circle.fill", withConfiguration: checkConfig)
        checkImage?.withTintColor(.systemGreen).draw(in: CGRect(x: 280, y: 100, width: 80, height: 80))

        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 28, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let text = "识别完成"
        let textSize = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: CGPoint(x: (size.width - textSize.width) / 2, y: 200),
            withAttributes: attrs
        )

        // 显示识别结果预览
        if !liveText.isEmpty {
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: UIColor.lightGray
            ]
            let preview = String(liveText.prefix(40))
            let rect = CGRect(x: 40, y: 250, width: size.width - 80, height: 40)
            (preview as NSString).draw(in: rect, withAttributes: subAttrs)
        }
    }

    // MARK: - UIImage -> CMSampleBuffer

    private func createSampleBuffer(from image: UIImage) -> CMSampleBuffer? {
        guard let cgImage = image.cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height

        // 创建 pixel buffer
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32ARGB,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else {
            print("[PiP] CVPixelBufferCreate failed: \(status)")
            return nil
        }

        // 渲染图片到 pixel buffer
        CVPixelBufferLockBaseAddress(pb, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(pb, [])

        // 创建 format description
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescriptionOut: &formatDescription
        )
        guard let format = formatDescription else {
            print("[PiP] FormatDescription creation failed")
            return nil
        }

        // 创建 sample timing info
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(seconds: 0.5, preferredTimescale: 600),
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )

        // 创建 sample buffer
        var sampleBuffer: CMSampleBuffer?
        let bufferStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        guard bufferStatus == noErr else {
            print("[PiP] CMSampleBufferCreate failed: \(bufferStatus)")
            return nil
        }

        return sampleBuffer
    }

    // MARK: - 清理

    func cleanup() {
        stopFrameTimer()

        stateLock.lock()
        recordingStartTime = nil
        liveText = ""
        isSetupComplete = false
        let layerToRemove = displayLayer
        pipController = nil
        hostView = nil
        displayLayer = nil
        stateLock.unlock()

        // 在主线程移除 layer
        DispatchQueue.main.async {
            layerToRemove?.removeFromSuperlayer()
        }
    }

    // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

    @objc func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
    }

    @objc func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    @objc func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        return false
    }

    @objc func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        pushFrame()
    }

    @objc func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    // MARK: - AVPictureInPictureControllerDelegate

    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        print("[PiP] Will start PiP")
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        print("[PiP] Did start PiP - app can now go to background")
        NotificationCenter.default.post(name: .pipDidStart, object: nil)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        print("[PiP] Failed to start: \(error.localizedDescription)")
        print("[PiP] Error code: \((error as NSError).code)")
    }

    func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        print("[PiP] Will stop PiP")
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        print("[PiP] Did stop PiP")
        NotificationCenter.default.post(name: .pipDidStop, object: nil)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        NotificationCenter.default.post(name: .pipDidRestore, object: nil)
        completionHandler(true)
    }
}

// MARK: - 通知

extension Notification.Name {
    static let pipDidRestore = Notification.Name("com.daseanle.votype.pipDidRestore")
    static let pipDidStart = Notification.Name("com.daseanle.votype.pipDidStart")
    static let pipDidStop = Notification.Name("com.daseanle.votype.pipDidStop")
}
