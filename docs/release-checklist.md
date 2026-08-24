# VoType 1.0 发布验收清单

本清单区分“源码/CI 已验证”和“必须在 Apple 账号或真机完成”的事项。只有所有必需项通过后，才能把版本称为可发布。

## 1. 源码与 CI

- [x] `xcodegen generate` 成功，`project.yml` 是唯一项目配置源。
- [x] `VoTypeTests` 在可用 iPhone 模拟器全部通过；找不到模拟器时 CI 必须失败。
- [x] Release 的无签名 device build 通过。
- [x] App 与 Keyboard Extension 都包含 `PrivacyInfo.xcprivacy`。
- [x] `project.yml` 中候选版本为 build 35，大于已上传的 build 33；CI 仍会使用 run number 覆盖构建号。
- [x] 普通 PR / push 不会调用 `pilot upload` 或 `deliver`。
- [x] 手动发布只有在 `publish=true` 时才会访问 App Store Connect。

验证证据：2026-08-24 的 [PR #1 / Build IPA #90](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/32686345974) 已通过全部 XCTest、无签名 iphoneos Release 构建、IPA 打包与 artifact 上传；发布相关步骤均按条件跳过。

## 2. Apple Developer 与签名

- [x] 主 App ID `com.daseanle.votype` 和键盘 App ID `com.daseanle.votype.keyboard` 已启用 `group.com.daseanle.votype.container`。
- [ ] CI 已重新生成两份 App Store provisioning profile，并验证均包含该 App Group。
- [ ] 开发 provisioning profile 已按需重新生成；不影响 TestFlight 分发构建。
- [x] CI 不再依赖仓库中的 App Store profile secrets；证书、密码、API Key 或 profile 内容均不写入仓库或文档。
- [ ] 签名归档中主 App 与扩展的 entitlement 均包含正确 App Group。

## 3. 真机功能

至少覆盖 iOS 16 的最低兼容设备、当前正式 iOS、iOS 26，以及一台 iPad。

- [ ] 首次授权、拒绝后重试、从设置重新授权均可恢复。
- [ ] App Group 会话设置能从键盘传到宿主 App，识别结果只返回同一 session。
- [ ] App/扩展被系统杀掉后，不会把旧结果自动插到错误 App 或输入框。
- [ ] 宿主可响应时原地开始；宿主被挂起时清楚提示打开 VoType，且录音开始后返回原输入框仍能显示实时文字。
- [ ] listening 状态再次点麦克风可停止；starting 取消、processing 重复停止及迟到回调不会产生双结果。
- [ ] 左滑 QWERTY 的字母、Shift、数字、符号、空格、回车、短按/长按删除和地球键在 iPhone/iPad 可用。
- [ ] 在 QWERTY 补字期间仍能看到语音状态，并可一次点击结束录音。
- [ ] 中文、英文及至少一种日韩/欧洲语言使用正确 locale 和标点。
- [ ] 翻译开关、目标语言、个人词典、自动标点、口水词、列表格式化分别验证。
- [ ] 语音“替换、追加、删除”都验证，删除不能插入命令原文。
- [ ] 断网时：支持设备端识别的语言正常工作；不支持时给出准确错误，不宣称离线可用。
- [ ] 电话、Siri、蓝牙切换、耳机插拔和其他音频中断后不会卡死或误录。
- [ ] 从旧版本升级后，实验性后台待命偏好被关闭，且不会再启动近静音音频或合成画中画。
- [ ] 内存、能耗、麦克风指示和后台音频行为符合产品披露。

## 4. App Store 合规决策

源码已移除以下两条不受支持的路径；仍须在候选构建和归档中复核：

- [x] 键盘扩展不依赖 responder-chain 调用 `UIApplication.open` 启动宿主 App。
- [x] 商店构建源码不使用近静音噪声或合成画中画维持后台执行。

这两项源码检查通过不等于 App Review 已通过；最终结论仍以签名候选包和 Apple 审核为准。

## 5. 隐私与商店材料

- [ ] 隐私政策 URL `https://aimarshalllee.github.io/voice-input-keyboard/privacy-policy.html` 返回 200。
- [ ] App Store Connect 的 Privacy Details 与隐私政策、代码行为一致。
- [ ] 中文和英文描述只宣称真机端到端验证过的能力。
- [ ] 删除“完全离线、语音不离开设备、无需切 App、无限时长、自动语言检测、日期自动格式化”等不准确表述。
- [ ] 现有 `fastlane/screenshots` 不得用于发布：它们包含缺字方框、重叠文字、与实际键盘不一致的界面和未实现宣称。
- [ ] 使用当前候选 TestFlight build 在真机重新截图；逐张以 100% 比例检查文字、图标、语言和隐私表述。
- [ ] 支持 URL、隐私 URL、截图尺寸和所有本地化元数据通过 Fastlane precheck。

## 6. TestFlight 与发布

- [ ] 手动运行发布 workflow，确认 archive / export、IPA 和 dSYM 可追溯。
- [ ] 等待 App Store Connect 完成 build processing，而不只验证上传命令成功。
- [ ] 安装处理完成的 TestFlight build，执行一次完整回归。
- [ ] 填写加密出口、隐私问卷、审核说明和键盘测试步骤。
- [ ] 先邀请内部测试；外部测试稳定后再提交 App Review。
- [ ] App Review 通过且公开商店页可查询后，才把项目状态改为“已发布”。
