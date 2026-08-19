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
    private var frameTimer: Timer?
    private var recordingStartTime: Date?
    private var liveText: String = ""

    // MARK: - 状态

    var isPiPActive: Bool {
        pipController?.isPictureInPictureActive ?? false
    }

    var canStartPiP: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    // MARK: - 初始化

    /// 在指定 view 上设置 PiP 显示层
    /// 必须在 viewDidAppear 之后调用,确保 view 有 window
    func setup(in view: UIView) {
        hostView = view

        // 移除旧 layer
        displayLayer?.removeFromSuperlayer()

        let layer = AVSampleBufferDisplayLayer()
        layer.frame = view.bounds
        layer.backgroundColor = UIColor.black.cgColor
        view.layer.insertSublayer(layer, at: 0)
        displayLayer = layer

        // 创建 PiP 控制器
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        pipController = controller

        // 推送第一帧
        pushFrame()
    }

    // MARK: - 开始 / 停止 PiP

    func startPiP() {
        guard let controller = pipController else {
            print("[PiP] No controller")
            return
        }

        if !controller.isPictureInPictureActive {
            controller.startPictureInPicture()
        }

        // 开始定期刷新画面 (显示录音时长 + 波形)
        recordingStartTime = Date()
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pushFrame()
        }
    }

    func stopPiP() {
        frameTimer?.invalidate()
        frameTimer = nil
        recordingStartTime = nil

        // 推送最后一帧 (完成状态)
        pushFrame(isFinal: true)

        // 通知 PiP 控制器状态已变更
        pipController?.invalidatePlaybackState()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.pipController?.stopPictureInPicture()
        }
    }

    /// 更新悬浮窗中显示的实时识别文本
    func updateLiveText(_ text: String) {
        liveText = text
        pushFrame()
    }

    // MARK: - 画面生成

    private func pushFrame(isFinal: Bool = false) {
        guard let layer = displayLayer else { return }

        let image = generateRecordingImage(isFinal: isFinal)
        guard let buffer = createSampleBuffer(from: image) else { return }

        layer.enqueue(buffer)
    }

    /// 生成录音状态画面
    private func generateRecordingImage(isFinal: Bool) -> UIImage {
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

            if isFinal {
                // 完成状态
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

                let subAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 18),
                    .foregroundColor: UIColor.lightGray
                ]
                let subText = "请返回键盘,文字已就绪"
                let subSize = (subText as NSString).size(withAttributes: subAttrs)
                (subText as NSString).draw(
                    at: CGPoint(x: (size.width - subSize.width) / 2, y: 250),
                    withAttributes: subAttrs
                )
            } else {
                // 录音中状态
                let micConfig = UIImage.SymbolConfiguration(pointSize: 60, weight: .bold)
                let micImage = UIImage(systemName: "mic.fill", withConfiguration: micConfig)
                micImage?.withTintColor(.systemRed).draw(in: CGRect(x: 290, y: 60, width: 60, height: 60))

                // 录音时长
                var duration = ""
                if let start = recordingStartTime {
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
        frameTimer?.invalidate()
        frameTimer = nil
        recordingStartTime = nil
        displayLayer?.removeFromSuperlayer()
        displayLayer = nil
        pipController = nil
        hostView = nil
    }

    // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

    @objc func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        // 不需要控制播放/暂停
    }

    @objc func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        // 返回从0开始的无限时长,让 PiP 持续保持活跃
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    @objc func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        // 永远不在暂停状态,保持 PiP 活跃
        return false
    }

    @objc func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // 渲染尺寸变化时重新推送画面
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
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        print("[PiP] Failed to start: \(error.localizedDescription)")
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
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // 用户点击了 PiP 的还原按钮,回到全屏 App
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
