# VoType 1.0 发布验收清单

本清单区分“源码/CI 已验证”和“必须在 Apple 账号或真机完成”的事项。只有所有必需项通过后，才能把版本称为可发布。

## 1. 源码与 CI

### Recorded Slice A automated source evidence — Build IPA #187

下列证据仅适用于源码 `e02308bf65b4bf96991c0537400ed3601b42ffd2` 的 [Build IPA #187](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/36795409018)，该 run 于 2026-10-01 UTC 成功（14m07s）；不是签名候选、TestFlight 或真机验收。

- [x] 246 个单元测试通过（0 failures / 0 unexpected；40.832 秒 test time、60.644 秒 wall time）；4 个唯一的 containing-app 模拟器 UI 用例在两套 scheme 下通过（54.635 秒、54.467 秒），不代表键盘扩展或真机 UI。
- [x] 20 轮 IPC（1.764 秒）、50-session（0.756 秒）及 100-iteration terminal-race（1.811 秒）通过；15 个 Apple adapter 测试、3 个 engine cancellation/timeout/supersession 回归测试及 TextProcessor cleanup（0.104 秒）通过。
- [x] 生成 plist 校验与 keyboard distribution source gate 通过；无签名 generic iOS device Release build 于 00:30:12 UTC 完成，无签名 archive 于 00:31:21 UTC 完成，CI 检查主 App 与 Keyboard Extension bundle directories 均存在。
- [x] artifact `11133738244`（5,265,680 bytes）已生成；外层 ZIP SHA-256 为 `8cfbfd01eccb151d450a398a7335bf4ea3476aaec80e6a1956dbfae0081f6568`，其中 IPA SHA-256 为 `83d94c2f7507a021d63688851a302507f06d73a61dd0df3c415c0cbc43b270c1`，两者对应不同对象。
- [x] IPA/archive plists 显示 bundle IDs `com.daseanle.votype` 与 `com.daseanle.votype.keyboard`、version 1.0、build 187、minimum iOS 16.0。IPA 无 `_CodeSignature` 或 `embedded.mobileprovision`；未运行 `codesign`，因此没有签名验证或可安装性结论。

R37 behavioral RED 见 Build #184 与 #186；#185 仅为 compile-seam failure，不算 behavioral RED；#187 是上述精确源码 SHA 的 green run。所有 Apple certificate/profile/signing/upload/metadata 步骤均跳过。

### Historical Slice A automated evidence — Build IPA #183

历史证据适用于源码 `b3be44b88cba83a5768af199ed30f2eec85fdaa6` 的 [Build IPA #183](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35538673741)，成功于 2026-09-20 UTC，不是签名候选、TestFlight 或真机验收。

- [x] 235 个单元测试通过（0 failures / 0 unexpected），包含 20 轮、50 session 和 100 iteration 终态竞态压力用例。
- [x] 4 个唯一的 containing-app 模拟器 UI 用例在两套 scheme 下通过；不代表键盘扩展或真机 UI。
- [x] 生成 plist 校验与 keyboard source gate 通过。
- [x] 无签名 generic iOS device Release build 通过；无签名 archive 通过，且 CI 检查主 App 与 Keyboard Extension 均存在。
- [x] 归档 artifact `10613729361` 已生成；GitHub 外层 ZIP SHA-256 为 `db2d5cc8d0e82596928d2002a8392ea677aef8128ddc7a8b1125b5e5e6805355`，包含 IPA 的 SHA-256 为 `59c882880c4875fa8d37f0090d53da893c23bc4390b8bf52271d2d97bff57a82`，两者不是同一对象。

该次运行跳过所有 Apple certificate/profile/signing/upload/metadata 步骤；无签名产物不构成可安装性、签名、TestFlight 或 App Review 证据。

Signed physical-device microphone, Apple Speech, PiP lifecycle, extension eviction, and third-party insertion remain EXTERNAL / NOT_RUN for Slice A.

以下既有 workflow/source checks 与 Build IPA #134 的结论均为历史记录，不替代当前 Slice A 候选证据。

- [x] `xcodegen generate` 成功，`project.yml` 是唯一项目配置源。
- [x] `VoTypeTests` 在可用 iPhone 模拟器全部通过；找不到模拟器时 CI 必须失败。
- [x] `VoTypeUITests` 在模拟器验证免切换入口、麦克风关闭披露和拼音学习重置入口。
- [x] Release 的无签名 device build 通过。
- [x] 无签名 Release `.xcarchive` 同时包含主 App 与 Keyboard Extension。
- [x] App 与 Keyboard Extension 都包含 `PrivacyInfo.xcprivacy`。
- [x] `project.yml` 中源码构建号为 35；CI 使用 run number 覆盖候选构建号。
- [x] 普通 PR / push 不会调用 `pilot upload` 或 `deliver`。
- [x] 手动发布只有在 `publish=true` 时才会访问 App Store Connect。
- [x] 生成后的主 App `Info.plist` 在测试/上传前拒绝 Apple 不支持的 `UIBackgroundModes` 值。

历史验证证据：2026-08-26 的 [Build IPA #134](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/32884927580) 在 `main` 提交 `4aee78b880bc69d63f00272f74e9d7ae0c8989de` 上通过 73 个单元测试、3 个 UI 冒烟用例、20 轮顺序会话压力、无签名 iphoneos Release 构建与 `.xcarchive`；归档同时包含主 App 和 Keyboard Extension。IPA 与归档保存在 artifact `9577650532`，artifact ZIP SHA-256 为 `c5bdcdddf4a6c3bfab6e73d1e49f5e7240691466c5679ac4dd0dc9e9887accad`。

## 2. Apple Developer 与签名

### 历史签名证据：1.0 (146)

以下已勾选事项与签名校验只记录 2026-08-28 的历史候选 1.0 (146)，不表示当前 Slice A 候选已签名或准备好分发。该次受控发布流水线完成分发证书、两份 App Store profile、App Group、嵌套签名与 embedded profile UUID 校验。流水线使用 App Store Connect API Key，无需交互式 Apple Developer 登录，且未把凭据写入日志或仓库。

- [x] 主 App ID `com.daseanle.votype` 和键盘 App ID `com.daseanle.votype.keyboard` 已启用 `group.com.daseanle.votype.container`。
- [x] CI 已重新生成两份 App Store provisioning profile，并验证均包含该 App Group。
- [ ] 开发 provisioning profile 已按需重新生成；不影响 TestFlight 分发构建。
- [x] CI 不再依赖仓库中的 App Store profile secrets；证书、密码、API Key 或 profile 内容均不写入仓库或文档。
- [x] 签名候选包中主 App 与扩展的 entitlement 均包含正确 App Group，且证书 SHA 与 embedded profile UUID 已逐一核对。

历史验证证据：2026-08-28 的 [Build IPA #146](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/33088265846) 在提交 `01b3db482fb25821e8f4281ee66a3a8991e9051e` 上通过 88 个单元测试、4 个 UI 测试、20 轮会话压力以及 profile、证书、Bundle ID、App Group、嵌入 profile 与嵌套签名校验。

### CURRENT Slice A 候选签名状态

截至 2026-10-01，本轮确认的 Slice A 源码证据是无签名 Build IPA #187；下列当前候选签名门禁均未完成：

- [ ] 为当前 Slice A 候选生成签名包并重新验证证书、profile、entitlements 和嵌套签名。
- [ ] 验证当前候选的开发描述文件（如真机测试所需）。

## 3. 真机功能

本节全部属于 **EXTERNAL / NOT_RUN**，模拟器与 CI 不得将任一项改为通过。

至少覆盖 iOS 16 的最低兼容设备、当前正式 iOS、iOS 26，以及一台 iPad。

- [ ] 首次授权、拒绝后重试、从设置重新授权均可恢复。
- [ ] App Group 会话设置能从键盘传到宿主 App，识别结果只返回同一 session。
- [ ] App/扩展被系统杀掉后，不会把旧结果自动插到错误 App 或输入框。
- [ ] 开启免切换语音后，键盘显示实心麦克风，点击不切 App 且 1.5 秒内进入 listening；待命时系统麦克风指示保持关闭。
- [ ] 用户或系统关闭 PiP 后 readiness 在 3.5 秒内过期，键盘变为空心麦克风，不显示假待命。
- [ ] 冷启动时点空心麦克风会保存请求并立即提示手动打开 VoType；用户从主屏幕打开 App 后恢复请求，键盘不尝试拉起宿主。
- [ ] 中文拼音可连续输入、展示并点选候选词，空格选择首候选；中英文、数字和符号切换不丢失或重复上屏。
- [ ] listening 状态再次点麦克风可停止；starting 取消、processing 重复停止及迟到回调不会产生双结果。
- [ ] 左滑 QWERTY 的字母、Shift、数字、符号、空格、回车、短按/长按删除和地球键在 iPhone/iPad 可用。
- [ ] 在 QWERTY 补字期间仍能看到语音状态，并可一次点击结束录音。
- [ ] 中文、英文及至少一种日韩/欧洲语言使用正确 locale 和标点。
- [ ] 翻译开关、目标语言、个人词典、自动标点、口水词、列表格式化分别验证。
- [ ] 语音“替换、追加、删除”都验证，删除不能插入命令原文。
- [ ] 断网时：支持设备端识别的语言正常工作；不支持时给出准确错误，不宣称离线可用。
- [ ] 电话、Siri、蓝牙切换、耳机插拔和其他音频中断后不会卡死或误录。
- [ ] 画中画必须由用户在前台明确开启，显示待命/录音/整理的真实产品状态；关闭后立即撤销原地可用状态。
- [ ] 待命阶段不激活录音音频会话、不播放近静音音频；只有键盘会话开始后才启用麦克风。
- [ ] 内存、能耗、麦克风指示和后台音频行为符合产品披露。

## 4. App Store 合规决策

当前架构包含 Apple 平台限制下的两条兼容路径，必须在候选构建和审核前如实复核：

- [x] 空心麦克风不调用 responder-chain 或 `NSExtensionContext.open` 等不受支持的键盘拉起 API；它只保存可恢复请求并显示手动打开操作。Apple 不保证自定义键盘可拉起宿主。
- [x] 不使用近静音噪声或待命录音保活。
- [ ] 用户主动开启的 PiP 显示真实 VoType 状态和隐私提示；App Review 是否接受该产品用途仍待审核，不能把源码通过等同于审核通过。

源码、CI 和真机检查均不等于 App Review 已通过；最终结论仍以签名候选包和 Apple 审核为准。

## 5. 隐私与商店材料

- [x] `documentation/` 已覆盖架构、权限流程、配置/Secrets、自动化、测试映射、首次启动、数据保留/删除、签名归档和回滚。
- [x] `LICENSE`、`THIRD_PARTY_NOTICES.md`、拼音词库作者与 Apache-2.0 许可文件存在并与实际依赖一致。
- [x] `CHANGELOG.md` 只写用户可见能力和必要操作，不宣称已通过真机或审核。
- [x] 公共支持页已写入 `docs/support.html`，Fastlane 中英文支持 URL 已指向该页。
- [x] 隐私政策 URL `https://aimarshalllee.github.io/voice-input-keyboard/privacy-policy.html` 返回 200。
- [x] 支持 URL `https://aimarshalllee.github.io/voice-input-keyboard/support.html` 返回 200。
- [ ] App Store Connect 的 Privacy Details 与隐私政策、代码行为一致。
- [ ] 中文和英文描述只宣称真机端到端验证过的能力。
- [x] 已从 App 内、Fastlane 文案和公开政策删除“完全离线、语音不离开设备、保证无需切 App、无限时长、自动语言检测、日期自动格式化”等不准确表述。
- [ ] 现有 `fastlane/screenshots` 不得用于发布：它们包含缺字方框、重叠文字、与实际键盘不一致的界面和未实现宣称。
- [ ] 使用当前候选 TestFlight build 在真机重新截图；逐张以 100% 比例检查文字、图标、语言和隐私表述。
- [ ] 支持 URL、隐私 URL、截图尺寸和所有本地化元数据通过 Fastlane precheck。
- [x] `upload_metadata` 默认并继续保持关闭；没有明确选择不会上传元数据/截图。

公共页面证据：2026-08-26 的 [Deploy Pages #6](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/32884927637) 在提交 `4aee78b880bc69d63f00272f74e9d7ae0c8989de` 上成功，随后分别请求隐私政策与支持 URL，均真实返回 HTTP 200。

## 6. TestFlight 与发布

### 历史发布证据：1.0 (146)

以下已勾选事项与 TestFlight 证据只记录 2026-08-28 的历史候选 1.0 (146)，不表示当前 Slice A 候选已上传、处理或分发。历史 build 146 完成 TestFlight 上传、processing 和 Internal Testers 分发。App Review 仍为 **EXTERNAL / NOT_RUN**，当时未上传元数据/截图，也未提交审核。build 137 已被真机反馈否决，不得继续作为候选。

- [x] 手动运行发布 workflow，签名 IPA 已保存为可追溯的 GitHub Actions artifact。
- [x] App Store Connect 已完成 build 146 processing，而不只是上传命令成功。
- [x] Build 125 的 profile/证书/签名/IPA 均通过，但 App Store Connect 以 90112 拒绝无效 `picture-in-picture` Info.plist 值；根因已修复并加入 CI 门禁，build 125 不可测试。
- [ ] 安装处理完成的 TestFlight build，执行一次完整回归。
- [ ] 填写加密出口、隐私问卷、审核说明和键盘测试步骤。
- [x] Build 1.0 (146) 已分发给 Internal Testers；真机稳定且用户明确确认后再考虑提交 App Review。
- [ ] App Review 通过且公开商店页可查询后，才把项目状态改为“已发布”。

历史 TestFlight 证据：[Build IPA #146](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/33088265846) 日志确认 `Successfully finished processing the build 1.0 - 146 for IOS` 及 `Successfully distributed build to Internal testers`。签名 IPA artifact `9653577030` 为 1,350,433 bytes，下载 ZIP SHA-256 为 `0099703679af978e6a14a6d5749a73bb55cb52173a9ec0d4bf4d5435c268f6f8`。build 137 已被真机失败否决；build 115 早于关键修复，build 125 上传失败，均不得替代当前 Slice A 候选。`Upload Metadata and Screenshots` 在 build 146 中保持跳过，App Review 未触发。

### CURRENT Slice A TestFlight 状态

当前无签名 Slice A Build IPA #187 不是 TestFlight 构建；以下当前候选分发门禁未完成：

- [ ] 当前 Slice A 候选经授权签名后上传到 App Store Connect / TestFlight。
- [ ] 当前 Slice A 候选在 App Store Connect 完成 processing。
- [ ] 当前 Slice A 候选分发给 Internal Testers。
- [ ] 当前 Slice A TestFlight 构建完成真机回归；真实设备门禁仍为 EXTERNAL / NOT_RUN。
