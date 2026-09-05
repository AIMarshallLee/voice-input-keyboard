# VoType 持续交付台账

更新：2026-09-05。仅记录经过核对的事实；未提交工作不计入已合并实现。

## 当前目标与断点

- 目标：按已确认商用 V1 规格完成可靠、简洁的语音键盘；当前只执行 Slice A。
- 职责机制：[窗口 Agent 规划书](../docs/superpowers/specs/2026-09-05-votype-continuous-delivery-agent-charter.md)，用户已回复“同意”。
- 规格：[商用 V1](../docs/superpowers/specs/2026-09-04-voice-first-commercial-v1-design.md)。
- 实施计划：[Slice A 九任务](../docs/superpowers/plans/2026-09-04-slice-a-reliable-session-engine.md)。
- 当前断点：Task 1–4 已取得真实 RED、GREEN 和独立审查 PASS，实施验收进度 **4/9**。统一引擎、超时/竞态/重用门禁已通过，但尚未接入现有前台/PiP，不能据此认定 App 真机可用。
- 下一动作：Task 5 已进入测试先行阶段，接入 Apple、文本处理与 Darwin 输出适配；先取得 macOS RED 再实现。

## 源码与工作区身份

- 主仓库：`D:\Obsidian\voice-input-keyboard`
- 唯一实施工作树：`D:\Obsidian\voice-input-keyboard\.worktrees\slice-a`
- 当前分支：`codex/slice-a-reliable-session-engine`
- 实施基线：`a5045f21286ec831170c93f7321a57ec346b57c6`；linked worktree 已建立。原始 checkout 保持规划分支，不并行修改业务代码。
- 原有规格、实施计划、职责稿与台账已在授权后提交为 `a5045f2`；没有丢弃原差异。
- 草稿 [PR #13](https://github.com/AIMarshallLee/voice-input-keyboard/pull/13) 已创建，未合并。
- `project.yml` 是生成工程的唯一来源；现有测试 target 包含整个 `VoTypeTests` 目录。
- Task 1–4 已验收；新测试通过 `xcodegen generate` 编入。Task 5 基线为 `5247153`。

## 授权状态

| 动作 | 当前范围 |
|---|---|
| 目标、职责与连续执行方法 | 2026-09-05 用户“同意”；范围内本地研发、只读检查、测试准备和项目记录可推进 |
| 新工作树/分支、commit、push、PR、远端 CI | 2026-09-05 用户明确允许；本任务可按门禁推进 |
| main 合并 | 2026-09-05 明确包含；仅合并经过审阅及准确提交门禁的本任务差异 |
| 内部 TestFlight | 2026-09-05 明确包含；适用构建通过门禁后可分发，不表示真机通过 |
| Apple/凭据、App Store 发布 | 2026-09-05 明确包含；凭据仅处理确有必要的问题且不外泄。App Store 保留真机通过后确认提交门槛，不现在提交 |
| heartbeat | 未启用；最终回复后不保证后台继续，等待下次触发 |

最新授权来源：用户明确回复“允许本项目创建隔离开发分支、提交和非强制推送、创建 PR 并运行其 macOS CI；包含合并 main、修改凭据、TestFlight 或 App Store 发布”。不迁移到其他项目；不把授权本身当作完成证据。

## Slice A 任务

| 任务 | 交付内容 | 实施/验收状态 |
|---|---|---|
| 1 | Canonical Session 与向后兼容 IPC | 完成：`f5a1fb7`，#151 GREEN，独立审查 PASS |
| 2 | 依赖端口与同步音频屏障 | 完成：`c6ed787`，#153 GREEN，独立审查 PASS |
| 3 | 引擎主路径与命令语义 | 完成：`f0a591a`，#156 GREEN，独立审查 PASS |
| 4 | 截止时间、迟到回调、竞态与重用 | 完成：`5247153`，#159 GREEN，独立审查 PASS |
| 5 | Apple、文本、Darwin 生产适配 | 进行中：准备失败测试，生产适配尚未实现 |
| 6 | PiP/原地输入迁移 | 待做 |
| 7 | 前台呈现迁移 | 待做 |
| 8 | 移除不支持的拉起与手动结果保留 | 待做 |
| 9 | 全量回归、Release/Archive 与文档 | 待做 |

任务只有在实现、相应测试及审查证据齐全后才标为完成。后续 Slice 在前片出口有新证据且自己的实施计划完成审查后才能实施。

## 验证路径与本轮证据

- `git status --short` / `git branch --show-current` / `git rev-parse --git-dir --git-common-dir --show-superproject-working-tree`：确认上述 checkout 与保留差异。
- `Get-Command xcodebuild` / `Get-Command swift`：两者当前均不可用。环境缺失不算测试 RED，也不能算测试通过。
- `.github/workflows/build.yml`：现有测试运行在 `macos-26`；执行 XcodeGen、VoTypeTests 和 VoTypeUITests。
- 该流水线由 PR、main push 或手动 dispatch 触发；普通开发分支 push 本身不会触发。优先使用 PR 路径，它跳过 `Check Development Signing Secrets`；不能将 `publish=false` 手动运行描述为必定不接触现有开发签名配置。
- [基线 CI #149](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/33952292055) **SUCCESS**，源码 `a5045f2`；88 单元、4 个独立 UI 测试、unsigned Release/Archive/打包通过，Apple 签名和分发步骤跳过。工作流报告 Node20 action 迁移提示，未借此升级无关依赖。
- [Task 1 RED #150](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/33952943674)，源码 `b15505687c3054b7a008c264e3a0534fbc2af0bf`：Unit/UI 编译按预期失败，缺少 SessionToken/EditPlan/commit/peek/cancel notification/fingerprint。测试先于生产实现提交。
- [Task 1 GREEN #151](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/33954007796) **SUCCESS**（9m51s），源码 `f5a1fb71b75f58ff22d7314092aa9dec1c7581e0`：实际日志确认 Constants 41、Models 5、总单元 100、4 个独立 UI 均零失败，unsigned Release/Archive 成功。artifact `9965882959`（VoType-IPA，4,761,899 bytes）是无签名 CI 产物。独立 reviewer_sol 完成源码审查与证据收口，Task 1 PASS；本地 Python plist 检查 2/2 PASS。
- 已知警告未掩盖：计划要求保留的 deprecated Bool wrappers、旧前台/后台 main-actor 调用警告由 Task 6/7 迁移处理；已有 UIKit/AppIntents/模拟器目标和 Node/Homebrew runner 提示在最终门禁复核。#151 checkout 曾连接失败后自动恢复，未修改 runner trust 或项目依赖。没有将有警告的输出描述为零警告。
- 本机 Git 直连失败后，Task 1 通过精确 blob/tree/commit 哈希校验的 GitHub Git Data API 以 `force=false` 同步，未改变历史或凭据；随后单命令使用现有系统代理的普通 Git 读取已恢复。后续优先普通 Git，不修改全局配置。
- [Task 2 RED #152](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/33954833600)，源码 `815350d88535987ec924d72fd88a089a16ad127c`：环境准备成功后，08:18:39Z 测试编译因缺少 `DictationSpeechSession` 按预期失败。
- [Task 2 GREEN #153](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/33955132256) **SUCCESS**（13m08s），源码 `c6ed78713fb0d271a659544496c5c6276814903d`：同步屏障 2/2（0.066s）、全单元 102/102、4 个独立 UI、unsigned Release/Archive 通过；实际日志没有点名三个 Task 2 文件的 warning/error。独立 reviewer_sol 源码与证据收口 PASS；真实麦克风/PiP 不在此结论内。
- Task 3 实施前架构复核纠正了计划竞态：同步保留旧会话结束信息并释放旧资源后才接受新会话，异步保存仅操作冻结流；授权恢复后再次核对 token/generation/phase。加入三个请求交错、授权发布挂起和资源关闭顺序测试，不将已知不安全的中间实现留给后续任务修复。Task 4 的 partial timer 按固定窗口合并，不按每次 partial 重置为 debounce。
- [Task 3 初始 RED #154](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/33956489168)，源码 `b25dd977a6165aafc99ba1ea5c4a24b70dd2f70b`：2026-09-05 08:54:33Z 实际日志报告测试辅助代码缺少 `DictationSessionEngine`，环境准备正常。后补用例的新 RED 与实现 GREEN 见下；没有以缺少 Windows 工具代替此证据。
- Task 3 已验证约束：`capture.start()` 抛错仍停止已创建的 capture；首次接受 final 文本后忽略该会话迟到的识别回调，但保留取消和音频中断控制。Task 4 已把停止后、final 前部分识别接入超时兜底，见 #159 证据。
- [Task 3 补充 RED #155](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/33957946763)，源码 `724a9e69479939c40a91b3bb9449f3e31c7f8c94`：包含 11 个用例，09:26:57Z 实际编译因缺少生产引擎按预期失败。
- [Task 3 GREEN #156](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/33958290409) **SUCCESS**（11m53s），源码 `f0a591aaa54f524678d61f3b93196028c9d113fd`：引擎 11/11、全单元 113/113、4 个独立 UI、unsigned Release/Archive 通过。无诊断点名三个 Task 3 文件；已知旧路径/工具警告仍记录。独立审查源码及证据收口 PASS，Task 3 验收完成。artifact `9967245824` 为无签名 CI 产物，4,825,011 bytes，不是真机安装或分发证据。
- Task 4 已新增静音计时器代次：取消不能撤回已进入执行队列的旧计时器；用会话内 attempt 拒绝已被新语音替代的静音回调，避免过早停止。已通过本项测试与独立审查，不修改公开协议或 IPC。
- Task 4 测试初稿 [#157](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/33959352823) 含误写的 `harness.waitUntil`，未计为有效 RED；修正并加入停止屏障回归后，[RED #158](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/33959857447) 在 `16ce98f` 上只因缺少待实现的 `silenceExpired` 按预期失败。
- [Task 4 GREEN #159](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/33960319624) **SUCCESS**（11m14s），源码 `52471536daf5a67e924e7371d8f902ecd1fb836e`：引擎 25/25、全单元 127/127、4 个独立 UI、unsigned Release/Archive 通过；实际日志确认 100 轮终态竞争、50 次连续复用、旧静音回调拒绝及停止录音屏障用例通过。独立审查与证据收口 PASS；没有点名 Task 4 文件的诊断，已有警告仍记录。artifact `9967870025` 为无签名 CI 产物，4,828,983 bytes。
- Task 5 预检约束：现有实时发布器再次节流会拖慢引擎已合并的反馈，因此适配层使用立即发布；同一 MainActor 操作内检查 token 与递增 sequence 并落盘，拒绝迟到/重复/终态后回调。旧前台/后台调用以窄兼容重载保留到 Task 6/7 迁移；这些适配仍待实现。
- 真机语音/跨 App/权限/PiP：**EXTERNAL / NOT_RUN（本轮）**。历史用户测试曾暴露缺陷，不抹去历史结果。

## 发布基线

- 历史分发：1.0 (146)，源提交 `01b3db482fb25821e8f4281ee66a3a8991e9051e`；processing/Internal Testers 证据见 [版本报告](releases/1.0-build-146-testflight.md)。不是 Slice A 新产物或完整真机通过证据。
- 实施前最新已核对成功普通构建为 [Build IPA #148](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/33803082411)，源码 `ba3ca0e`，不是新 TestFlight 上传。新基线检查见上文。
- 本轮 PR #149 已生成自动化构建及无签名归档；尚无新签名、TestFlight processing 或分发结果，不将 PR 产物称为已发布版本。

## 阻塞与恢复

| 缺口 | 责任方/解除条件 | 解锁后首动作 |
|---|---|---|
| 本机无 Apple 测试运行时 | 使用获准的现有 macOS PR 流水线；已验证可用，不是当前阻塞 | 按任务继续 RED → 最小实现 → GREEN → 审查 |

此前的 Git/CI 授权阻塞已解除；继续实际实施，不通过改写验收标准或假造 Windows 测试结果绕开门禁。
