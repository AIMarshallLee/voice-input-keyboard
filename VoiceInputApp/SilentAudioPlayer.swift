import AVFoundation

/// 静音音频播放器 — 后台保活核心技术
///
/// iOS 判断一个 App 是否"正在播放音频"的依据不是 audio session 是否 active,
/// 而是**是否有 AVAudioPlayer/AVAudioEngine 正在播放**。
/// 只 setActive 不播放,iOS 会在几十秒到几分钟后挂起 App。
///
/// 本类持续播放一段极低音量噪声,让 iOS 认为 App 在"播放音频",
/// 从而保持 App 在后台存活。
///
/// 关键: 不能用全零数据 + volume=0!
/// iOS 会检测到"没有实际音频"并暂停播放器。
/// 改用极低振幅随机噪声 + volume=0.01,iOS 认为是正常音频播放。
class SilentAudioPlayer {

    private var player: AVAudioPlayer?
    private var healthTimer: DispatchSourceTimer?
    private let healthLock = NSLock()
    private var healthGeneration: UInt = 0

    /// 开始播放无声音频 (无限循环)
    func start() {
        if player != nil {
            if player?.isPlaying == false {
                player?.play()
            }
            startHealthCheck()
            return
        }

        guard let data = SilentAudioPlayer.generateNearSilentWAV(seconds: 1) else {
            print("[SilentAudio] Failed to generate WAV")
            return
        }

        do {
            player = try AVAudioPlayer(data: data)
            player?.numberOfLoops = -1   // 无限循环
            player?.volume = 0.03        // 极低音量，iOS 不会认为是静音
            player?.prepareToPlay()
            player?.play()
            print("[SilentAudio] Started — background keep-alive active")
            startHealthCheck()
        } catch {
            print("[SilentAudio] Failed to init player: \(error.localizedDescription)")
        }
    }

    /// 暂停 (仅在需要麦克风独占时调用)
    func pause() {
        stopHealthCheck()
        player?.pause()
        print("[SilentAudio] Paused")
    }

    /// 恢复
    func resume() {
        guard let p = player else {
            start()
            return
        }
        if !p.isPlaying {
            p.play()
            print("[SilentAudio] Resumed — keep-alive restored")
        }
        startHealthCheck()
    }

    /// 完全停止
    func stop() {
        // 先使所有已排队的健康检查失效，避免 stop 后旧回调重新创建播放器。
        stopHealthCheck()
        player?.stop()
        player = nil
        print("[SilentAudio] Stopped")
    }

    // MARK: - 健康检查

    /// 每 2 秒检查一次播放器是否还在播放
    /// 如果被 iOS 暂停了，立即重启
    private func startHealthCheck() {
        stopHealthCheck()
        healthLock.lock()
        healthGeneration &+= 1
        let generation = healthGeneration
        healthLock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.isCurrentHealthGeneration(generation) else { return }
                guard self.player?.isPlaying != true else { return }
                print("[SilentAudio] Player stopped! Restarting...")
                self.player?.play()
                if self.player?.isPlaying != true,
                   self.isCurrentHealthGeneration(generation) {
                    self.player = nil
                    self.start()
                }
            }
        }
        timer.resume()
        healthLock.lock()
        if healthGeneration == generation {
            healthTimer = timer
        } else {
            timer.cancel()
        }
        healthLock.unlock()
    }

    private func stopHealthCheck() {
        healthLock.lock()
        healthGeneration &+= 1
        let timer = healthTimer
        healthTimer = nil
        healthLock.unlock()
        timer?.cancel()
    }

    private func isCurrentHealthGeneration(_ generation: UInt) -> Bool {
        healthLock.lock()
        defer { healthLock.unlock() }
        return healthGeneration == generation && healthTimer != nil
    }

    // MARK: - 生成极低音量噪声 WAV

    /// 生成一段极低振幅随机噪声的 WAV 文件
    /// 不是全零！全零会被 iOS 检测为静音并暂停播放器
    /// 振幅 1/32767，人耳几乎听不见，但 iOS 认为是有效音频
    static func generateNearSilentWAV(seconds: Int) -> Data? {
        let sampleRate = 44100
        let numChannels = 1
        let bitsPerSample = 16
        let numSamples = sampleRate * seconds
        let dataSize = numSamples * numChannels * (bitsPerSample / 8)

        var data = Data()

        // RIFF header
        data.append("RIFF".data(using: .ascii)!)
        appendUInt32(&data, UInt32(36 + dataSize))
        data.append("WAVE".data(using: .ascii)!)

        // fmt chunk
        data.append("fmt ".data(using: .ascii)!)
        appendUInt32(&data, 16)
        appendUInt16(&data, 1)                                     // PCM format
        appendUInt16(&data, UInt16(numChannels))
        appendUInt32(&data, UInt32(sampleRate))
        appendUInt32(&data, UInt32(sampleRate * numChannels * bitsPerSample / 8))
        appendUInt16(&data, UInt16(numChannels * bitsPerSample / 8))
        appendUInt16(&data, UInt16(bitsPerSample))

        // data chunk: 极低振幅随机噪声
        data.append("data".data(using: .ascii)!)
        appendUInt32(&data, UInt32(dataSize))

        // 生成低振幅噪声 (振幅 500，满量程 32767 的约 1.5%)
        // volume=0.03 → 实际播放音量约满量程的 0.045%，人耳几乎听不见
        // 但 iOS 不会判定为静音，不会暂停播放器
        // 之前振幅只有 1，iOS 检测到低能量后暂停 player → app 被挂起
        for _ in 0..<numSamples {
            let noise = Int16.random(in: -500...500)
            appendUInt16(&data, UInt16(bitPattern: noise))
        }

        return data
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: MemoryLayout<UInt32>.size))
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: MemoryLayout<UInt16>.size))
    }
}
