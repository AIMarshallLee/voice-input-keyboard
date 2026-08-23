# App Store 元数据工作稿

> 状态：待真机与 TestFlight 验收，不得直接提交。权威上传文本位于 `fastlane/metadata/`。

## 基本信息

- App 名称：声入（英文：VoType）
- 中文副标题：语音转文字键盘
- 英文副标题：Voice-to-Text Keyboard
- 主 App Bundle ID：`com.daseanle.votype`
- Keyboard Extension Bundle ID：`com.daseanle.votype.keyboard`
- App Group：`group.com.daseanle.votype.shared`
- SKU：`voiceinputkbd2026`
- 主要语言：简体中文
- 类别：工具（Utilities）
- 次要类别：效率（Productivity）
- 内容分级：4+
- 价格：免费
- 支持 URL：https://github.com/AIMarshallLee/voice-input-keyboard
- 隐私政策 URL：https://aimarshalllee.github.io/voice-input-keyboard/privacy-policy.html

## 准确性边界

商店文案只能描述已经在候选 TestFlight build 上完成端到端验证的能力：

- “20 个语言”指 20 个可手动选择的固定识别 locale，不是自动语言检测或任意混输。
- 设备支持时优先请求 Apple 设备端识别；不支持时 Apple Speech 可能联网处理，不得写“完全离线”或“语音不离开设备”。
- iOS 自定义键盘不能直接录音；用户可能需要在 VoType App 完成听写并手动返回原 App。
- Foundation Models 润色和翻译仅限模型可用的 iOS 26+ 设备。
- 当前格式化实现覆盖编号列表和标点，不宣称日期格式化。
- 不承诺无限会话时长。
- 实验性后台待命尚未完成 App Store 合规决策，不进入商店卖点。

中文和英文正式描述分别维护在：

- `fastlane/metadata/zh-Hans/description.txt`
- `fastlane/metadata/en-US/description.txt`

## 审核备注草稿

VoType 包含一个自定义键盘扩展和宿主 App。由于 iOS 不允许自定义键盘扩展直接访问麦克风，录音和 Apple Speech 识别由宿主 App 完成。键盘与宿主 App 仅通过同一 App Group 的本地共享容器交换用户主动发起的会话设置和结果。

测试步骤：

1. 打开 VoType，授权麦克风和语音识别。
2. 设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 声入。
3. 为声入开启“允许完全访问”，该权限用于 App Group 本地会话交换。
4. 在测试 App 的普通文本框中切换到声入键盘。
5. 点击麦克风；如 VoType 打开，在 App 中完成听写。
6. 手动返回测试 App 并切回声入键盘，确认匹配结果插入。

隐私政策：https://aimarshalllee.github.io/voice-input-keyboard/privacy-policy.html

## 截图

现有 `fastlane/screenshots/` 仅是历史占位素材，存在缺字方框、文字重叠、虚假离线宣称和与实际键盘不一致的界面，不能发布。

必须从当前候选 TestFlight build 真机重新截取：

1. 宿主 App 安装与权限引导；
2. 实际键盘界面；
3. 前台听写及实时预览（如该设置已开启）；
4. 结果返回和插入；
5. 语言、个人词典和隐私说明。

每张截图在 100% 比例检查文字、图标、语言和宣称，再放入 Fastlane 目录。所需设备尺寸以提交时 App Store Connect 的最新要求为准。

## 发布状态

- GitHub Actions 已在 2026-08-20 对 build 33 完成构建和上传动作。
- 工作流使用过跳过处理等待的上传方式，因此这不证明 TestFlight processing 成功。
- 当前没有证据表明版本已经提交审核或公开上架。
- 完整门槛见 [发布验收清单](release-checklist.md)。
