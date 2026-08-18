# VoType · 声入

iOS 语音输入键盘 — 离线语音转文字、AI 润色、实时翻译、语音编辑、场景感知、20 语言支持。全面对标并超越 Typeless，且完全免费、完全离线、零网络传输。

## 品牌名称

- **English**: VoType (Voice + Type)
- **中文**: 声入 (声 = voice, 入 = input, echoes "声入人心")

## 核心功能

| 功能 | 说明 |
|------|------|
| 离线语音转文字 | on-device 识别，零网络 |
| AI 文字润色 | iOS 26+ 设备端 LLM |
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

## 项目结构

```
VoType/
├── project.yml                    # XcodeGen 配置
├── .github/workflows/build.yml    # GitHub Actions 云端编译
├── VoiceInputApp/                 # 主 App (设置 + 引导)
│   ├── VoiceInputApp.swift
│   ├── ContentView.swift
│   ├── en.lproj/InfoPlist.strings  # 英文区名称: VoType
│   └── zh-Hans.lproj/InfoPlist.strings  # 中文区名称: 声入
├── KeyboardExtension/             # 键盘扩展
│   ├── KeyboardViewController.swift
│   ├── TextProcessor.swift        # AI 处理核心
│   ├── WaveformView.swift
│   ├── en.lproj/InfoPlist.strings
│   └── zh-Hans.lproj/InfoPlist.strings
└── Shared/                        # 共享文件
    ├── LanguageManager.swift      # 20 语言管理
    ├── SmartFormatter.swift       # 智能格式化
    ├── TranslationManager.swift   # 翻译管理
    └── UsageTracker.swift          # 使用统计
```

## 云端编译

项目使用 GitHub Actions 在 `macos-14` runner 上自动编译，无需本地安装 Xcode。

- 推送到 `main` 分支自动触发
- 配置签名 Secrets 后自动产出签名 IPA
- 未配置则产出未签名 IPA

## 安装配置

1. 安装 IPA 到设备 (需签名)
2. 设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 选择 VoType
3. 点击 VoType → 开启「允许完全访问」
4. 打开 VoType App 授权语音识别和麦克风

## 系统要求

- iOS 16.0+ (LLM/翻译功能需 iOS 26+)
- 支持 iPhone 和 iPad
