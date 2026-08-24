# VoType · 声入

VoType 是一个 iOS 语音转文字键盘原型，由宿主 App 负责录音与文字处理，键盘扩展负责发起会话和插入结果。

当前仓库的目标是得到一个可重复构建、可真机验收的 1.0 稳定版。源码可以在 Xcode 26 上构建；App Store 发布仍需完成真机测试、App Group 描述文件更新和真实商店截图，详见 [发布验收清单](docs/release-checklist.md)。

## 已实现能力

- Apple Speech 语音转文字；设备支持时优先使用设备端识别，否则识别请求可能由 Apple 服务处理
- 中文、英语、日语、韩语、德语、法语、西班牙语等 20 个固定识别语言
- 自动标点、口水词过滤、口语自我纠正和编号列表格式化
- 个人词典、语言偏好和本地使用统计
- 选中文字后的替换、追加和删除指令
- iOS 26+ 的设备端 Foundation Models 润色与翻译（仅在模型可用时）
- 深色模式、常用符号、空格、删除、回车和输入法切换键
- 键盘内的 starting / listening / processing 实时状态与节流转写预览
- 可左滑进入的英文 QWERTY 补字键盘（字母、数字、符号、Shift、长按删除）
- 再点麦克风停止录音；切换 App 或扩展重建后按输入框上下文安全恢复

“20 个语言”表示可手动选择 20 个识别 locale，不表示自动语言检测或任意语言混输。翻译与 LLM 润色在不支持 Foundation Models 的设备上会安全跳过。

## 架构

iOS 不允许自定义键盘扩展直接访问麦克风，因此录音必须由宿主 App 完成：

1. 键盘创建带唯一 session ID 的听写请求。
2. 请求写入按 session 隔离的 App Group 文件，并用 Darwin notification 通知宿主 App。
3. 宿主 App 使用 `SFSpeechRecognizer` 和 `AVAudioEngine` 录音、识别并处理文本。
4. 宿主持续发布 starting / listening / processing 快照，最终结果以 first-writer-wins 原子写回。
5. 取消墓碑与会话事务阻止迟到回调复活；键盘只消费 session 匹配且未过期的结果。
6. 键盘扩展被系统重建或切换输入框时，只有上下文哈希仍匹配才自动插入，否则要求用户确认。

共享容器标识为：

```text
group.com.daseanle.votype.container
```

主 App 与键盘扩展的 App ID、开发描述文件和分发描述文件都必须启用这个 App Group。没有正确 entitlement 时，进程间设置与结果传递不会工作。

### 平台限制

- 键盘扩展不能直接录音。
- 从键盘扩展启动宿主 App 的 responder-chain 兼容路径不属于 Apple 支持的扩展 API，不能作为 App Store 版的可靠前提。
- 宿主仍可响应时可直接原地开始；否则键盘会保留请求并提示打开 VoType。看到“正在聆听”后可立即返回原输入框继续说话、看实时文字并再次点麦克风停止。
- 发布版不使用近静音音频或合成画中画保活。iOS 结束宿主进程后，下一次会话仍需要用户打开 VoType；公共 API 无法保证每次都零切换。
- Apple Speech 的可用性、时长和离线能力由设备、语言与系统状态决定；本项目不承诺无限时长或所有语言离线。

Apple 平台边界可参考 [Custom Keyboard Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html) 与 [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)。

## 项目结构

```text
.
├── project.yml                         # XcodeGen 唯一项目配置源
├── VoiceInputApp/                      # 宿主 App、录音与设置
├── KeyboardExtension/                  # 键盘 UI、会话触发与结果插入
├── Shared/                             # IPC、语言、处理、翻译和统计
├── VoTypeTests/                        # XCTest 回归测试
├── .github/workflows/build.yml         # CI 与手动发布
├── fastlane/metadata/                  # App Store 元数据
└── docs/                               # 隐私政策与发布清单
```

仓库中历史生成的 Xcode 工程不是权威配置。修改目标、Info.plist、版本或签名设置时只改 `project.yml`，然后重新运行 XcodeGen。

## 本地构建

需要 macOS、Xcode 26 和 XcodeGen：

```bash
brew install xcodegen
xcodegen generate
open VoType.xcodeproj
```

列出可用模拟器并运行测试：

```bash
xcrun simctl list devices available
xcodebuild test \
  -project VoType.xcodeproj \
  -scheme VoTypeTests \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  CODE_SIGNING_ALLOWED=NO
```

真机构建前，在 Apple Developer 后台完成以下配置：

1. 为 `com.daseanle.votype` 和 `com.daseanle.votype.keyboard` 启用 `group.com.daseanle.votype.container`。
2. 开发描述文件按需重新生成；TestFlight CI 会生成并严格校验两份 App Store 分发描述文件。
3. 在 Xcode 中确认两个 target 的签名团队和 App Group entitlement 一致。
4. 在设备设置中添加 VoType 键盘并按需开启“允许完全访问”。

## CI 与发布

- Pull Request 和 `main` push 只运行测试、构建并上传 CI 产物，不会上传 App Store Connect。
- App Store 上传只能从 `workflow_dispatch` 手动触发，并显式设置 `publish=true`。
- CI build number 使用 GitHub Actions run number，避免重复上传同一个 `CFBundleVersion`。
- 签名描述文件缺少 App Group 时，普通 CI 会安全回退为无签名构建；发布任务则应失败，不能生成一个跨进程功能失效的 IPA。

仓库不保存证书、私钥、描述文件或 App Store Connect API Key。相关值只应放在 GitHub Actions Secrets 中。

## 隐私

- 应用不包含广告、第三方分析或追踪 SDK。
- 音频仅在用户发起听写时交给 Apple Speech；设备不支持本地识别时可能使用 Apple 的在线识别服务。
- 会话设置、选中文本和识别结果会暂存在 App Group 共享容器，用于宿主 App 与键盘扩展交换；结果在匹配消费或过期后删除。
- 个人词典、功能设置和聚合使用次数保存在设备本地，不上传到开发者服务器。
- iOS 26+ 的 Foundation Models 处理在设备端完成。

完整说明见 [隐私政策](docs/privacy-policy.html)。

## 系统要求

- iOS / iPadOS 16.0+
- iOS 26+ 才可能使用 Foundation Models 润色与翻译
- 部分语言或设备需要网络连接才能使用 Apple Speech

## License

MIT
