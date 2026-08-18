# 语音输入键盘 (VoiceInputKeyboard)

一个 iOS 自定义键盘扩展,界面上有一个超大麦克风按钮,点击即可语音转文字并自动插入到输入框。专为在 iPad 上使用 UU远程等远程控制软件时便捷输入文字而设计。

## 解决什么问题

在 iPad 上用 UU远程控制电脑时,想要语音输入文字,正常流程是:

> 点击输入框 → 点右侧键盘按钮 → 找到麦克风按钮 → 点击 → 说话 → 点完成

需要点好几次按钮。本键盘把流程简化为:

> 点击输入框 → 切换到本键盘 → 点大麦克风按钮 → 说话 → 再点一次

## 项目结构

```
VoiceInputKeyboard/
├── project.yml                    # XcodeGen 配置(自动生成 Xcode 项目)
├── README.md                      # 本文件
├── VoiceInputApp/                 # 主 App
│   ├── VoiceInputApp.swift        # App 入口
│   ├── ContentView.swift          # 引导安装界面
│   └── Info.plist                 # 主 App 配置
└── KeyboardExtension/             # 键盘扩展
    ├── KeyboardViewController.swift  # 键盘主视图(麦克风按钮+录音+转写)
    ├── Info.plist                 # 键盘扩展配置
    └── (WaveformView 已内含在同一文件中)
```

## 安装方式

### 前置条件

- 一台 Mac 电脑
- Xcode 15 或更高版本(从 Mac App Store 免费下载)
- iOS 16 或更高的 iPad

### 方式一:使用 XcodeGen 自动生成(推荐)

```bash
# 1. 安装 XcodeGen(如果还没有)
brew install xcodegen

# 2. 进入项目目录
cd VoiceInputKeyboard

# 3. 生成 Xcode 项目
xcodegen generate

# 4. 打开项目
open VoiceInputKeyboard.xcodeproj
```

### 方式二:手动在 Xcode 中创建

1. 打开 Xcode → Create a new Xcode project
2. 选择 **iOS** → **App** → 填写:
   - Product Name: `VoiceInputApp`
   - Bundle Identifier: `com.voiceinput.app`
   - Interface: **SwiftUI**
3. 创建后,添加键盘扩展:
   - File → New → Target → **Keyboard Extension**
   - Product Name: `KeyboardExtension`
   - Bundle Identifier: `com.voiceinput.app.keyboard`
4. 将本项目中的源文件拖入对应目录:
   - `VoiceInputApp.swift` 和 `ContentView.swift` → 主 App
   - `KeyboardViewController.swift` → 键盘扩展
5. 用项目中的 `Info.plist` 替换自动生成的

## 配置键盘

安装 App 到 iPad 后,需要进行以下配置:

### 第一步:添加键盘

1. 打开 iPad **设置**
2. **通用** → **键盘** → **键盘** → **添加新键盘**
3. 在列表中找到 **语音输入** → 点击添加

### 第二步:允许完全访问

1. 在键盘列表中点击 **语音输入**
2. 开启 **允许完全访问**
3. 确认弹窗(这是使用麦克风的必要条件)

### 第三步:授权语音识别

1. 打开 **语音输入键盘** App(主 App)
2. 按照界面引导,点击授权按钮
3. 允许麦克风和语音识别权限

## 使用方法

1. 在 UU远程(或任何 App)中点击输入框
2. 键盘弹出后,如果显示的不是本键盘:
   - 点击键盘左下角的 **地球图标** 🌐 切换键盘
   - 或长按地球图标,在列表中选择「语音输入」
3. 点击中间的大麦克风按钮 🎤
4. 开始说话,屏幕上会实时显示识别结果和波形动画
5. 说完后再次点击按钮,文字自动插入到输入框

## 方案A:辅助触控(零代码备选方案)

如果不想开发 App,可以用 iPadOS 自带的辅助触控实现类似效果:

### 配置步骤

1. **设置** → **辅助功能** → **触控** → **辅助触控** → 打开
2. 点击 **创建新手势**
3. 在录制界面中模拟操作:
   - 点击 UU远程 右侧键盘按钮的位置
   - 长按空白处约 1 秒(等待键盘弹出)
   - 点击键盘上麦克风按钮的位置
4. 存储手势,命名为「语音输入」
5. 在辅助触控设置中,将 **单点** 操作绑定到「语音输入」手势

### 使用

在 UU远程 中点击输入框 → 单击辅助触控悬浮球 → 手势自动回放 → 开始说话

### 注意事项

- 保持 iPad 屏幕方向固定
- UU远程 画面缩放比例保持一致
- 界面布局变化后需重新录制

## 技术说明

### 架构

本键盘扩展采用直接录音方案:

- 键盘扩展开启 **RequestsOpenAccess**(完全访问),可直接访问麦克风
- 使用 **AVAudioEngine** 录制音频
- 使用 **SFSpeechRecognizer** 实时语音转文字(优先设备端识别)
- 通过 **textDocumentProxy.insertText()** 将文字插入当前输入框

不需要在主 App 和键盘扩展之间切换,所有操作在键盘内完成。

### 权限说明

| 权限 | 用途 | 何时请求 |
|------|------|---------|
| 麦克风 | 录制语音 | 首次点击麦克风按钮时 |
| 语音识别 | 将语音转为文字 | 首次点击麦克风按钮时 |
| 完全访问 | 允许键盘访问上述功能 | 添加键盘后手动开启 |

### 隐私

- 所有语音识别优先使用设备端模型(on-device),不发送到服务器
- 不收集、不存储、不传输任何用户数据
- 不包含任何第三方 SDK 或分析工具

## 常见问题

**Q: 点击麦克风按钮提示「请开启允许完全访问」**
A: 设置 → 通用 → 键盘 → 键盘 → 点击「语音输入」→ 开启「允许完全访问」

**Q: 识别不准确**
A: 确保说话清晰,靠近麦克风。中文识别需要 iOS 内置的中文语音包(通常已预装)。

**Q: 键盘不出现**
A: 在输入框上长按地球图标 🌐,在列表中选择「语音输入」。如果列表中没有,回到设置添加键盘。

**Q: 手势方案(方案A)在 UU远程 中点击位置偏了**
A: UU远程 的界面布局可能因缩放比例不同而变化。确保使用时缩放比例与录制时一致,或重新录制手势。

**Q: 能否支持其他语言?**
A: 代码中默认设置为中文(zh-CN)。如需其他语言,修改 `KeyboardViewController.swift` 中的 `setupSpeechRecognizer()` 方法里的 locale。

## 系统要求

- iOS 16.0+
- Xcode 15+(用于编译)
- iPad(支持 iPad mini / Air / Pro 全系列)
