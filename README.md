# VoType · 声入

iOS 语音输入键盘 — 语音转文字、AI 润色、实时翻译、语音编辑、场景感知、20 语言支持。PiP 悬浮窗录音,和 Typeless / 微信输入法同款方案。

## 品牌名称

- **English**: VoType (Voice + Type)
- **中文**: 声入 (声 = voice, 入 = input, echoes "声入人心")

## 核心功能

| 功能 | 说明 |
|------|------|
| 语音转文字 | Apple Speech Framework,支持在线/离线识别 |
| PiP 悬浮窗 | 录音时悬浮窗显示,可滑回宿主 App 继续操作 |
| AI 文字润色 | iOS 26+ 设备端 LLM (Foundation Models) |
| 智能自我纠正 | 7 种口语纠正模式检测 |
| 自动标点 | 按语言规则自动添加 |
| 口水词过滤 | 中英文口水词自动去除 |
| 智能自动格式化 | 检测列表/步骤模式转编号列表 |
| 实时翻译 | 说中文输出英文 (iOS 26+) |
| 场景感知 | 邮件/URL/社交自动调整风格 |
| 语音编辑 | 选中文字说话即可替换/追加/删除 |
| 耳语模式 | 安静环境增强语音捕获 |
| 20 语言支持 | 中英日韩德法西俄等 |
| 使用统计 | 字数/会话/语言分布/连续天数 |
| 个人词典 | 自定义替换词 + 批量导入 |

## 技术架构

### iOS 键盘扩展录音限制

iOS 平台禁止键盘扩展直接录音 (`Client was NOT allowed to start recording because it is an extension and doesn't have entitlements to record audio`)。VoType 采用 **容器 App + PiP 悬浮窗** 方案绕过此限制:

1. 用户在键盘中点击麦克风按钮
2. 键盘通过 URL Scheme (`votype://dictation?lang=zh-CN`) 启动容器 App
3. 容器 App 开始录音 + 启动 PiP 悬浮窗
4. 用户可以向上滑回宿主 App (如微信),录音在悬浮窗中继续
5. 识别完成后,文字通过 Named Pasteboard 传回键盘
6. 用户回到键盘,文字自动插入到输入框

### PiP 悬浮窗实现

使用 Apple 公开 API 实现,与 Typeless 和微信输入法同款方案:

- `AVPictureInPictureController` + `AVSampleBufferDisplayLayer`
- `AVPictureInPictureSampleBufferPlaybackDelegate` 协议
- `UIBackgroundModes: audio` 保持 App 后台存活
- `AVAudioSession` 配置 `.mixWithOthers` 不打断其他 App 音频
- 悬浮窗实时显示录音时长 + 识别文本 + 波形动画

### 关键文件

| 文件 | 说明 |
|------|------|
| `PiPManager.swift` | PiP 悬浮窗管理器 (AVPictureInPictureController) |
| `DictationView.swift` | 容器 App 录音页面 (自动录音 + PiP 集成) |
| `KeyboardViewController.swift` | 键盘扩展主控制器 (URL Scheme 触发 + Pasteboard 读取) |
| `DictationConstants.swift` | URL 参数 + Named Pasteboard 通信 |
| `TextProcessor.swift` | AI 文字处理核心 |
| `TranslationManager.swift` | 翻译管理 (iOS 26+ Translation Framework) |
| `LanguageManager.swift` | 20 语言管理 |
| `SmartFormatter.swift` | 智能格式化 |
| `UsageTracker.swift` | 使用统计 |

## 项目结构

```
VoType/
├── project.yml                    # XcodeGen 配置
├── .github/workflows/build.yml    # GitHub Actions 云端编译 + 自动上传 TestFlight
├── VoiceInputApp/                 # 主 App (设置 + 录音 + PiP)
│   ├── VoiceInputApp.swift         # App 入口 + URL Scheme 处理
│   ├── ContentView.swift           # 设置页面
│   ├── DictationView.swift         # 录音页面 + PiP 集成
│   ├── PiPManager.swift            # PiP 悬浮窗管理器
│   ├── en.lproj/InfoPlist.strings
│   └── zh-Hans.lproj/InfoPlist.strings
├── KeyboardExtension/             # 键盘扩展
│   ├── KeyboardViewController.swift
│   ├── TextProcessor.swift
│   ├── WaveformView.swift
│   ├── en.lproj/InfoPlist.strings
│   └── zh-Hans.lproj/InfoPlist.strings
└── Shared/                        # 共享文件
    ├── DictationConstants.swift
    ├── LanguageManager.swift
    ├── SmartFormatter.swift
    ├── TranslationManager.swift
    └── UsageTracker.swift
```

## 云端编译

项目使用 GitHub Actions 在 `macos-26` runner (Xcode 26) 上自动编译:

- 推送到 `main` 分支自动触发
- 配置签名 Secrets 后自动产出签名 IPA
- 自动上传到 App Store Connect (TestFlight)
- 自动上传元数据和截图

### 必需的 GitHub Secrets

| Secret | 说明 |
|--------|------|
| `CERTIFICATE_P12` | 开发证书 (base64) |
| `CERTIFICATE_PASSWORD` | 证书密码 |
| `PROVISIONING_PROFILE_APP` | App 描述文件 (base64) |
| `PROVISIONING_PROFILE_KEYBOARD` | 键盘扩展描述文件 (base64) |
| `DIST_CERTIFICATE_P12` | 发布证书 (base64) |
| `DIST_CERTIFICATE_PASSWORD` | 发布证书密码 |
| `DIST_PP_APP` | App 发布描述文件 (base64) |
| `DIST_PP_KEYBOARD` | 键盘发布描述文件 (base64) |
| `ASC_KEY_ID` | App Store Connect API Key ID |
| `ASC_ISSUER_ID` | App Store Connect Issuer ID |
| `ASC_KEY_CONTENT` | App Store Connect API Key (base64) |

## 安装配置

1. 安装 IPA 到设备 (需签名) 或通过 TestFlight 安装
2. 设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 选择 VoType
3. 点击 VoType → 开启「允许完全访问」
4. 打开 VoType App 授权语音识别和麦克风
5. 在任意 App 中切换到 VoType 键盘,点击麦克风开始语音输入

## 系统要求

- iOS 16.0+ (LLM/翻译功能需 iOS 26+)
- 支持 iPhone 和 iPad
- 语音识别需网络连接 (Apple 服务器识别)

## License

MIT
