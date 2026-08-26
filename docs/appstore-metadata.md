# App Store 元数据工作稿

> 状态：商用候选材料。仍待最终真机、真实截图、Apple 账号字段和人工审核提交；不得直接提交。权威上传文本位于 `fastlane/metadata/`。

## 基本信息

- App 名称：声入（英文：VoType）
- 中文副标题：语音转文字键盘
- 英文副标题：Voice-to-Text Keyboard
- 主 App Bundle ID：`com.daseanle.votype`
- Keyboard Extension Bundle ID：`com.daseanle.votype.keyboard`
- App Group：`group.com.daseanle.votype.container`
- SKU：`voiceinputkbd2026`
- 主要语言：简体中文
- 类别：工具（Utilities）
- 次要类别：效率（Productivity）
- 内容分级：4+
- 价格：免费
- 支持 URL：https://aimarshalllee.github.io/voice-input-keyboard/support.html
- 隐私政策 URL：https://aimarshalllee.github.io/voice-input-keyboard/privacy-policy.html

## 准确性边界

商店文案只能描述已经在当前签名候选和真机上完成端到端验证的能力；
当前候选 1.0 (137) 已签名、完成 TestFlight processing 并分发内部测试，但尚未完成真机端到端矩阵，因此以下边界继续生效：

- “20 个语言”指 20 个可手动选择的固定识别 locale，不是自动语言检测或任意混输。
- 设备支持时优先请求 Apple 设备端识别；不支持时 Apple Speech 可能联网处理，不得写“完全离线”或“语音不离开设备”。
- iOS 自定义键盘不能直接录音；用户可能需要在 VoType App 完成听写并手动返回原 App。
- Foundation Models 润色和翻译仅限模型可用的 iOS 26+ 设备。
- 当前格式化实现覆盖编号列表和标点，不宣称日期格式化。
- 不承诺无限会话时长。
- 用户可在前台明确开启显示真实状态的画中画待命；待命不录音，关闭后撤销 readiness。有效待命时可原地开始，但不承诺系统始终保留待命或每次都无需打开 VoType。
- 键盘包含离线中文拼音/英文 QWERTY 补字层和实时会话反馈，但只有在当前候选签名并通过真机后才能加入正式卖点。

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
5. 在 VoType 明确开启“免切换语音”，确认画中画显示“待命不录音”。
6. 回到输入框，确认实心麦克风原地进入聆听；再次点击停止并检查结果只插入一次。
7. 关闭画中画，等待 3.5 秒，确认麦克风变为空心且不显示假待命。
8. 点击空心麦克风；若系统拒绝跳转，确认 3 秒内提示从主屏幕打开 VoType。
9. 左滑进入拼音/英文键盘，验证候选、数字、符号和长按删除。

隐私政策：https://aimarshalllee.github.io/voice-input-keyboard/privacy-policy.html

## 截图

现有 `fastlane/screenshots/` 仅是历史占位素材，存在缺字方框、文字重叠、虚假离线宣称和与实际键盘不一致的界面，不能发布。

必须从当前候选完成签名、TestFlight processing 后的同一 build 真机重新截取：

1. 宿主 App 安装与权限引导；
2. 实际键盘界面；
3. 返回原输入框后的实时预览与停止状态；
4. 结果返回和插入；
5. 语言、个人词典和隐私说明。

每张截图在 100% 比例检查文字、图标、语言和宣称，再放入 Fastlane 目录。所需设备尺寸以提交时 App Store Connect 的最新要求为准。

## 发布状态

- 2026-08-26 的 [Build IPA #137](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/32926693256) 在 `main` 提交 `668383d` 上通过 73 个单元测试、3 个 UI 冒烟、20 轮会话压力、分发 profile/证书/App Group/嵌套签名门禁，并生成签名 App Store IPA。
- [Deploy Pages #6](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/32884927637) 成功后，公开隐私政策与支持 URL 均已实际返回 HTTP 200。
- Build 125 的签名包通过构建但被 App Store Connect 以 90112 拒收；无效 `picture-in-picture` 后台值已移除并加入生成后 Info.plist 门禁。
- 当前候选已完成 Apple 分发签名、TestFlight 上传/processing 和 Internal Testers 分发；真机矩阵与 App Review 仍为 **EXTERNAL / NOT_RUN**。
- `upload_metadata` 保持关闭；现有截图不得上传。当前没有提交审核或公开上架。
- 完整门槛见 [发布验收清单](release-checklist.md) 和 [App Store 提交清单](../documentation/app-store-submission.md)。
