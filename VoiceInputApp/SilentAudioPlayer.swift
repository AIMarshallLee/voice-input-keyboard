import AVFoundation

/// 静音音频播放器 — 后台保活核心技术
///
/// iOS 判断一个 App 是否"正在播放音频"的依据不是 audio session 是否 active,
/// 而是**是否有 AVAudioPlayer/AVAudioEngine 正在播放**。
/// 只 setActive 不播放,iOS 会在几十秒到几分钟后挂起 App。
///
/// 本类持续播放一段无声音频(全零 WAV),让 iOS 认为 App 在"播放音频",
/// 从而保持 App 在后台存活。这是 Typeless / 微信输入法 / 导航类 App
/// 后台保活的核心技术。
///
/// 体积:1 秒 44.1kHz 单声道 16bit = 88KB,内存中生成,不写磁盘
class SilentAudioPlayer {

    private var player: AVAudioPlayer?

    /// 开始播放无声音频 (无限循环)
    func start() {
        if player != nil {
            if player?.isPlaying == false {
                player?.play()
            }
            return
        }

        guard let data = SilentAudioPlayer.generateSilentWAV(seconds: 1) else {
            print("[SilentAudio] Failed to generate silent WAV")
            return
        }

        do {
            player = try AVAudioPlayer(data: data)
            player?.numberOfLoops = -1   // 无限循环
            player?.volume = 0            // 完全静音
            player?.prepareToPlay()
            player?.play()
            print("[SilentAudio] Started — background keep-alive active")
        } catch {
            print("[SilentAudio] Failed to init player: \(error.localizedDescription)")
        }
    }

    /// 暂停 (录音时调用,释放麦克风给 AVAudioEngine)
    func pause() {
        player?.pause()
        print("[SilentAudio] Paused for recording")
    }

    /// 恢复 (录音结束后调用,恢复后台保活)
    func resume() {
        guard let p = player else {
            start()
            return
        }
        if !p.isPlaying {
            p.play()
            print("[SilentAudio] Resumed — keep-alive restored")
        }
    }

    /// 完全停止
    func stop() {
        player?.stop()
        player = nil
        print("[SilentAudio] Stopped")
    }

    // MARK: - 生成静音 WAV

    /// 在内存中生成一段全零(静音)的 WAV 文件
    /// 格式: RIFF / WAVE / PCM / 44100Hz / 单声道 / 16bit
    static func generateSilentWAV(seconds: Int) -> Data? {
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
        appendUInt32(&data, 16)                                    // fmt chunk size
        appendUInt16(&data, 1)                                     // PCM format
        appendUInt16(&data, UInt16(numChannels))
        appendUInt32(&data, UInt32(sampleRate))
        appendUInt32(&data, UInt32(sampleRate * numChannels * bitsPerSample / 8)) // byte rate
        appendUInt16(&data, UInt16(numChannels * bitsPerSample / 8))              // block align
        appendUInt16(&data, UInt16(bitsPerSample))

        // data chunk (all zeros = silence)
        data.append("data".data(using: .ascii)!)
        appendUInt32(&data, UInt32(dataSize))
        data.append(Data(count: dataSize))

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
