# VoType 持续交付台账

更新：2026-09-21。仅记录经过核对的事实；未提交工作不计入已合并实现。

## 当前目标与断点

- 目标：按已确认商用 V1 规格完成可靠、简洁的语音键盘；当前只执行 Slice A。
- 职责机制：[窗口 Agent 规划书](../docs/superpowers/specs/2026-09-05-votype-continuous-delivery-agent-charter.md)，用户已回复“同意”。
- 规格：[商用 V1](../docs/superpowers/specs/2026-09-04-voice-first-commercial-v1-design.md)。
- 实施计划：[Slice A 九任务](../docs/superpowers/plans/2026-09-04-slice-a-reliable-session-engine.md)。
- 当前断点：Task 1–7 已取得真实 RED、GREEN 和独立审查 PASS，实施验收进度 **7/9**。前台迁移 `faedeb6` 已修复退出、重开时丢失后继请求的问题并通过准确提交验证；这不是整个 App 的真机验收。
- 下一动作：Task 8 第二轮 `3fc8d00` / #181 仍在 macOS 验证。独立复审确认原三项 Important 已修复，但新发现 result-only 写入残留可能被误当成已确认终态并清掉迁移身份。父级核实后已补两条 R36 回归，先取得实际行为 RED，再最小修复结案判定。保持 **7/9**，不因旧问题修复或测试通过就提前验收。

## 自主执行约定（2026-09-20 生效）

- 用户明确要求自行设置目标、完成大部分任务、减少询问。本任务已设置活动目标：交付已批准的商用 V1；按 A → B → C → D 推进，不把 Slice A 或 TestFlight 成功等同于产品完成。
- 范围内自行选择下一项、安排实现与独立审查、修复失败、运行验证并执行已授权 Git/CI 操作；技术细节和可逆取舍由本窗口负责，不再逐项询问“是否继续”。沿用下表已有授权，不重复索取。
- 每片以实现、准确提交的测试、审查及可追溯证据闭环；只有本片出口通过才推进依赖它的实现。后续片实施计划由本窗口准备及审查，偏离已批准产品范围的重大取舍才提交用户。
- 需要用户的事项集中为：本人登录/验证码等无法代办的账号操作、真实 iPhone 验收与主观体验反馈、新增付费或越出授权的高风险操作、真机通过后的最终 App Store 提交确认。等待其中一项时继续独立且已授权的工作。
- 本轮核对 PR #13 仍为 Draft/Open、远端 HEAD `36f9ed8`、最近 CI #161 成功；这不覆盖已发现的两项审查缺陷。恢复现有 EXTRA RED 差异，不重做 Task 1–4。
- 活动目标不等于定时器。遵守 2026-09-12 全局暂停自动化的决定，不自行恢复 heartbeat；在当前及后续获调度的目标运行中接续台账，不承诺关闭应用后永久后台执行。

## 源码与工作区身份

- 主仓库：`D:\Obsidian\voice-input-keyboard`
- 唯一实施工作树：`D:\Obsidian\voice-input-keyboard\.worktrees\slice-a`
- 当前分支：`codex/slice-a-reliable-session-engine`
- 实施基线：`a5045f21286ec831170c93f7321a57ec346b57c6`；linked worktree 已建立。原始 checkout 保持规划分支，不并行修改业务代码。
- 原有规格、实施计划、职责稿与台账已在授权后提交为 `a5045f2`；没有丢弃原差异。
- 草稿 [PR #13](https://github.com/AIMarshallLee/voice-input-keyboard/pull/13) 已创建，未合并。
- `project.yml` 是生成工程的唯一来源；现有测试 target 包含整个 `VoTypeTests` 目录。
- Task 1–7 已验收；新测试通过 `xcodegen generate` 编入。Task 8 基线为 `faedeb6`，Task 7 全范围基线为 `829e3b8`。

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
| 5 | Apple、文本、Darwin 生产适配 | 完成：`d58ed40` / #164 GREEN，两项审查问题修正，独立复审 PASS |
| 6 | PiP/原地输入迁移 | 完成：`829e3b8` / #166 GREEN，独立规格、代码与证据审查 PASS |
| 7 | 前台呈现迁移 | 完成：`faedeb6` / #170 GREEN，后继准入修复及独立规格/质量/证据复审 PASS |
| 8 | 移除不支持的拉起与手动结果保留 | 修复中：第二轮 `3fc8d00` 原三项 Important 已关闭，但新增一项 result-only 结案问题；R36 两条回归已准备，#181 自动门禁待结果 |
| 9 | 全量回归、Release/Archive 与文档 | 待做 |

任务只有在实现、相应测试及审查证据齐全后才标为完成。后续 Slice 在前片出口有新证据且自己的实施计划完成审查后才能实施。

## 验证路径与本轮证据

- 第二轮独立复审覆盖 `20f9f7c..3fc8d00` 五提交：原三项 Important 均 ADDRESSED，新增一项 Important。若 result 写成而 receipt 写入及 result 回滚删除都失败，API 返回 ioFailure，但残留 payload 被新 helper 当作终态，可能释放/清掉迁移链接。R36 明确仅有效取消标记或 receipt 能解除链接；fresh result-only 仍可保留恢复并由真实消费建立 receipt，过期文本仍按原 TTL 清理。已准备 2 条真实文件回归，尚未取得其 RED；不把 fixture 当作实际 I/O 双故障注入。

- R35 引用保护候选 `3fc8d00db938a92a64691add0245368f676dc45d` / [CI #181](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35537452948) 运行中。私有引用检查覆盖两类 GC 和普通读取；专用回执读取使过期但仍被引用的有效证据继续阻止迟到写入。父级 plist 2/2（0.025s）、source gate、diff/staged 检查通过。旧混合异常/过期 fixture 的兼容调整无独立 RED，保留全部异常字节断言并要求异常移除后普通 TTL 清理恢复；该事实已交独立审查，不虚报测试经历。未合并或分发。

- [CI #180](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35536533480) 在准确 `1d80e3bd5f3bceef5f06ec8490489ef6948891a0` 完成 **定向行为 RED，10m9s**。233 单元共 18 个失败诊断，0 unexpected，仅落在 3 条新 R35 回归：引用链中间凭据被删/未解决状态复活/不能最终回收（5），普通读删掉证据后允许迟到写入（9），年轻或刷新过的源记录所引用证据被 GC 删除（4）。此前 3 条 PiP 时序与全部 R33 回归通过，23 条恢复测试零失败；4 个独立 UI 通过（85.632s）。无编译或环境失败；Release/Archive/分发因测试失败跳过。父级据实际证据授权最小桥接层修复，不计为 Task 8 完成。

- R33 四文件候选与 R35 三条回归已完成本地检查，准备准确提交的定向 RED：刷新后仍年轻的源记录必须保留替代会话的过期取消/终态证据，普通读取与迟到写入须继续尊重该证据，A→R→S 引用链必须逐层安全回收。R35 保护尚未实现；不把此候选称为完整修复或 GREEN。实际文件删除失败、隐藏 UIKit 回调及真实设备仍未执行。

- [CI #179](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35535580378) 在准确 `e1155b0f3f87902cfb82fd4bbd35e46ed42046ae` 完成 **缺失契约 RED，45s**。实际编译错误为 ConstantsTests 200/206/445/453 行缺少 `DarwinBridge.handoffRecovery`，另有 4 个派生的 `Equatable.none` 推断错误；无运行时测试，不虚报其他新 enum 已单独产生诊断。正常 setup/source gate 通过。至此同一实施者获准实施剩余 R33 桥接/恢复/键盘修复，整轮生产候选仍须新 GREEN 与独立复审。

- R33 精确契约测试已提交 `e1155b0f3f87902cfb82fd4bbd35e46ed42046ae`，[CI #179](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35535580378) 运行中。新增 3 条用例并强化已有回归，覆盖精确 replacement、真实 pending/live/result、存储不可用、多链接逐个取消和过期终态证据回收顺序。期望缺失接口 RED 尚待实际编译日志；后台排序候选刻意未包含在这次仅测试/文档提交中。未报告新 GREEN 或验收。

- [CI #178](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35534896738) 在准确 `e7d0da3bd2e40caa7b9ed9d5439527ef9c9f9d6c` 完成 **行为 RED，7m51s**：227 单元共 20 个失败诊断，仅落在 3 条已知 PiP 用例及 7 条新 R33 用例，0 unexpected。新失败真实证明链接缺失/重复取消丢失、未解决链接被 TTL/GC 清掉、异常记录被覆盖、claim 空隙错误进入 none/无关恢复/普通 Retry、存储不可用被当作无请求。4 个独立 UI 通过（113.652s）；无编译/环境失败。下一阶段只补精确决策契约，再实现桥接/恢复；后台待机排序已有未提交候选，不计入 GREEN。

- [CI #177](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35534527381) 已在准确 `b8080ba5e38a84451c7b47757ab422600d3318f6` 完成预期 **行为 RED，8m10s**。实际 220 单元仅 3 个失败、无 unexpected：均为新用例中取消尚挂起却已经显示 standby 的断言（302/325/352 行）；其余所有权、释放和后继检查未报错。4 个独立 UI 用例通过（69.274s）；无编译/环境失败，build/archive/distribution 跳过。此前本地观察 TLS 超时不影响这一经完整日志核对的结论。

- R33 七条真实 IPC 行为回归已提交 `e7d0da3bd2e40caa7b9ed9d5439527ef9c9f9d6c`，[CI #178](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35534896738) 运行中；覆盖 source→replacement 身份落盘/保留、claim 后无 live 的恢复空隙、取消失败与终态后释放。仍无生产变更，尚未读取实际 RED。#177 的本地观察命令曾因 API TLS 超时退出，但远端仍在运行；未把观察失败当作测试失败，也未重启任何 CI。

- [CI #176](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35533829022) 在准确 `20f9f7cbf44dcbbc737ac8fcfcae7ceba74da232` 完成 **SUCCESS，14m19s**。实际日志：217 单元零失败（25.704s / 29.775s wall），4 个独立 UI 用例在两个 scheme 下通过（182.075s / 54.046s），source gate、unsigned BUILD（20:08:15 UTC）和 ARCHIVE（20:09:04 UTC）通过。unsigned artifact `10611934207` 为 5,165,010 bytes；所有 Apple 签名、上传与元数据步骤 skipped。前轮 20 项新增回归全通过，Timer/MainActor 警告已消失；旧 UIKit/兼容 API/Node action 警告仍存在。复审仍有三项 Important，故不验收 Task 8、不合并、不分发。

- 第二轮取消时序测试 `b8080ba5e38a84451c7b47757ab422600d3318f6` 已提交并非强制推送，[CI #177](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35534527381) 已排队。三条新增用例使用现有 runner 的 test-only cancel gate，覆盖停录前不可待机、旧取消不可覆盖活动或已终态后继；尚未取得其实际行为 RED。生产代码未改；父级 plist 2/2（0.030s）及 diff/staged 检查通过。#176 的 Unit/UI 步骤已显示通过，完整 build/archive 结果及日志计数尚待核对。

- 首轮生产修复 `20f9f7cbf44dcbbc737ac8fcfcae7ceba74da232` 已提交并非强制推送，[CI #176](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35533829022) 确认运行。同一独立 reviewer 正按 `372dfec..20f9f7c` 三提交完整修复差异复审；四个生产文件改动、20 项新回归原样保留。父级新鲜 plist 2/2（0.027s）、source gate/脚本语法/diff/staged 检查通过，但尚无修复后 macOS GREEN 或审查 PASS。未增加验收数、未合并或分发。

- 首轮修复 Stage 2 测试提交 `efedb6e4d1f058f820dc6091535f896b368fa5e4` / [CI #175](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35532924020) FAILURE，1m3s：19:38:52Z 准确诊断为 `KeyboardSessionRecoveryStore.recoveryDecision` 缺失及派生类型推断错误，环境/source gate 正常。新增 12 项真实 IPC 回归已在生产前固定；编译先在恢复接口停止，没有声称另一个 cancellationEvidence 接口也已单独报错或测试已运行。父级据 #174/#175 两阶段证据授权同一实施者做四个生产文件的修复，尚未得到修复 GREEN。当前无签名、上传或 main 合并动作。

- 首轮修复 Stage 1 已取得真实行为 **RED**：`5279354` / [CI #174](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35532291436) FAILURE，9m41s。205 单元中新增 8 个用例产生 17 条失败（其中 5 条是预期取消未发生导致的有界等待抛错，不是环境失败）；其他单元无失败、4 个独立 UI 通过。日志逐项确认过早 cancel、无通知未 cancel、存储丢失不停、损坏 marker 被删除后晚写仍获准、GC 删除无效证据、过期 stage 未清理。无编译错误；Release/Archive/分发跳过。循环中的 listening 分支先失败，processing 分支尚未执行，不能把它记为独立已复现。下一步是已准备的 12 项恢复/取消状态接口测试，再观察缺失接口 RED 后改生产。

- Task 8 首轮修复先补 8 项行为回归，提交 `52793542c794f355c3acf685089b31d921af9c85` 已非强制推送，[CI #174](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35532291436) 已进入队列；测试仅调用既有接口，覆盖无通知取消、准入时序、旧 token、存储失效、取消证据与 stage 清理。尚未观察本轮 RED，不提前改生产。父级完整读差异及 teardown，plist 2/2（0.035s）和 diff/staged 检查通过。

- `372dfec` / [CI #173](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35531019490) **SUCCESS**，13m45s：实际 197 单元零失败（24.836s，26.327s wall）、4 个独立 UI 零失败（两 scheme 重复运行分别 174.522s / 51.008s，不算 8 个）、source gate、unsigned BUILD（19:15:59Z）和 ARCHIVE（19:16:47Z）通过。artifact `10610939870` / 5,050,883 bytes 是无签名产物，签名/Apple 上传跳过。该结果不覆盖独立审查确认的 receipt-only 禁用重试、迁移回滚双请求、快照遮挡；进一步只读检查确认后台不主动读取取消墓碑，键盘退出丢通知时无可靠停止上界。父级 R30/R31 与后续取消协调修复正在补测试。新 Timer 回调 main-actor 告警（KeyboardViewController:1853）也纳入修复；不宣称零警告或 Task 8 完成。

- Task 8 生产实现 `372dfec1f3fb5a0d57c6a86636780acd1fe9640f` 已提交并非强制推送，[CI #173](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35531019490) 已确认运行。实现手动恢复、双 UUID 迁移/取消、冻结预览三动作、选区保护及失败重试；source gate 置于测试与 unsigned Release 前。自查修正 responder traversal 正则漏检，并使失败迁移在 processing 时仍可按精确 token 重试。本地 plist 2/2（父级 0.025s）、source gate/语法/staged diff 通过，九类合成禁止调用分别被拒绝；脚本 Git 模式为 100755。独立规格/质量审查已启动；尚无本次 macOS GREEN，不增加已验收任务数，也没有合并或发布。

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
- [Task 5 RED #160](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/33962792398)，源码 `186f429f1cea795f484fc0a694440a7e1ffe489d`：11:15:37Z 实际编译因 typed processor 尚无必填 `voiceEditEnabled:` 参数按预期失败，相关类型推导错误由缺失签名引起；环境准备成功。已进入生产实现，尚无本项 GREEN 或验收结论。
- [Task 5 初版 CI #161](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/34011080880) **SUCCESS**（2026-09-06 04:16:27–04:27:41Z，11m14s），源码 `36f9ed8e8b70d23d5c88ac5bf127fcf60de7732b`：适配 6/6、文本处理 10/10、引擎 25/25、全单元 134/134、4 个独立 UI、unsigned Release/Archive 通过；artifact `9982608443` 为无签名产物，4,861,003 bytes。本地 plist 2/2 通过。
- Task 5 尚未验收：独立审查发现取消已获胜时仍可能发失败通知，以及异步文本处理中的共享统计复合写入缺少隔离。正在补充行为回归；修复保持 MainActor 在异步等待期间可重入，不让挂起的旧处理阻塞新会话。初版 CI 绿色不能覆盖这些审查发现。
- 2026-09-20 恢复执行：职责/计划校正提交 `fc38f13`，EXTRA RED 测试提交 `2ff8025ff7a77df60666312a0e75d679e177b78f` 已非强制推送；[CI #162](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35520386307) 已触发，初次核对为 queued。新增取消通知矩阵和带有限等待/清理的重叠文本处理回归；生产通知提取保持旧行为，隔离修复尚未应用。下一动作先核对本次真实行为失败，再最小修复，不能把排队当 RED/PASS。本地 plist 2/2 与 diff 检查通过。
- CI #162 已结束 FAILURE（6m12s）：136 个单元测试中的通知矩阵在 15:46:08Z 准确复现取消后多发 failed，计为 R21 有效 RED；重叠文本测试没有进入受控翻译，出现三次有限等待超时、结果 nil/统计 0，不能计为 R22 有效 RED。该独立 defaults suite 漏关默认启用的 LLM 润色；先关闭测试外部模型依赖，同时只修复已证实的 R21，再取得 R22 的准确行为失败。四个独立 UI 测试通过，后续构建/分发跳过；未伪称所有红色来自目标缺陷。
- `ab1cd70a76a6f928efaa4e0b19e9a07caf21b53f` 已提交并非强制推送：生产仅将 failed 通知限定到 `.written`，测试仅增加 `llmPolish=false`。新 [CI #163](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35520888792) 已核对为 in_progress；尚未取得新 GREEN，不能把修复提交等同于任务验收。下一步继续读取同一 run，不重复启动。
- CI #163 最终 FAILURE（8m53s），136 个单元只有 **1 处预期失败**：UTC 2026-09-20 15:56:40Z，`TextProcessorTests.swift:346` 的 `allRecordingsWereOnMainThread` 断言失败，受控等待、两次真实结果与统计次数均通过，确认为 R22 有效行为 RED。取消通知矩阵 0.001s 通过、适配 7/7、引擎 25/25、4 个独立 UI 通过。已开始方法级隔离最小修复；不改变文本算法或串行阻塞整个处理调用。
- [Task 5 GREEN #164](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35521959880) **SUCCESS**，准确源码 `d58ed40fe4ef94715360057b56ea22b698709b53`（UTC 2026-09-20 16:12:16–16:22:55，10m39s）。实际日志：136 单元零失败；取消通知矩阵 0.784s、重叠处理/主线程写入 0.035s 通过；4 个独立 UI 在两个 scheme 下均零失败；unsigned Release BUILD 与 ARCHIVE 成功。artifact `10608841457`（VoType-IPA，4,862,142 bytes）是无签名 CI 产物，不是 TestFlight。签名、App Store Connect 与元数据步骤全部跳过。本地 plist 2/2 通过；没有点名本次变更源文件的 warning/error，已有旧路径/工具提示仍保留。
- Task 5 独立修复复审 **PASS**：实际提交结果决定通知，文本/翻译方法级 MainActor 覆盖两处共享统计写入且保留等待期间的可重入性，未修改算法或添加整段串行队列。非阻断测试清理观察留待最终全分支复核：超时路径取消/释放 detached 任务，但不 join 后再删除独立 defaults 测试域，不影响本轮产品路径验收。Task 6 已交付单一实施者进行测试准备，未在 Task 5 未验收时替换生产入口。
- [Task 6 RED #165](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35523095204) **FAILURE**，准确源码 `e36cd2639428e9cbb9f4982a1e8e7218c435dd7e`（UTC 2026-09-20 16:33:42–16:34:31）。新增 13 个后台适配与 4 个 PiP 生命周期回归；环境、XcodeGen 与 plist 校验成功后，16:34:27Z 在 `DictationSessionTestDoubles.swift:765` 准确报缺少 `PiPStandbyPresenting`，随后 TEST FAILED。只有这处预期 missing-seam error，无 Windows/Xcode 缺失冒充 RED。生产适配 GO 已交给同一实施者，尚无本项 GREEN、合并或新分发。
- [Task 6 GREEN #166](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35523520321) **SUCCESS**，准确源码 `829e3b83814cd8cbbf0ce0a63cbd144c27c4c44d`（UTC 2026-09-20 16:41:55–16:50:03，8m8s）。153 单元零失败（14.549s / 26.716s wall），含后台适配 13/13、PiP 9/9、引擎 25/25；4 个独立 UI 在两个 scheme 均通过（54.838s / 41.645s）。挂起 A→B 准入 0.458s、启动中关闭 PiP 延迟取消 0.427s、真实引擎/Darwin 终态回执 0.045s、意外 EOF 0.223s 均通过。无签名 BUILD 16:49:27Z、ARCHIVE 16:49:57Z 成功；artifact `10609083953`（VoType-IPA，4,989,830 bytes）不是 TestFlight。签名、App Store Connect 和元数据步骤跳过。
- Task 6 独立规格/代码/证据审查 **PASS**，无本项待修问题；本地 plist 2/2、源码所有权门禁和 diff 校验通过。本次源文件没有命名 warning/error，既有工具提示仍保留。画中画适配器为 197 行，不再持有重复录音、权限、Speech、心跳或终态写入；保留 PiP 渲染/watchdog。用户可见的新 UUID Retry 交互明确属于 Task 8，未用无消费者变量冒充完成。此验收不放行整个 Slice A、真机或分发。
- [Task 7 RED #167](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35525427012) **FAILURE**，准确源码 `dc66ac1483fe0fdfef791aab9d248a07d9a0ab5f`（UTC 2026-09-20 17:18:17–17:20:42，2m25s）。23 个模型与 2 个协调器测试先于生产改造提交。17:20:36Z 模型测试明确报缺少带引擎/时限注入的 initializer、`engineIdentity`；其他 nil/production 推断错误由缺失接口引起，环境/XcodeGen/plist 正常。已向同一实施者发生产 GO；本项尚无 GREEN。预提交补充了同 UUID 重新领取时旧计时回调隔离（UI claim 身份）以及取消绑定的 2.5 秒完成关闭约束，不新增录音所有者或通用调度框架。
- [Task 7 初版 CI #168](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35525931280) **SUCCESS**，准确源码 `b7f2c3dc97c3ac3d4f823cfc8bc0ad9548fbc8f8`，build job 12m42s。实际日志为 170 单元零失败（模型 23、协调器 2）、4 个独立 UI 在两个 scheme 均通过，unsigned BUILD 17:39:26Z / ARCHIVE 17:40:16Z 成功；artifact `10609597995`（4,965,979 bytes）为无签名 CI 产物。没有点名本项变更文件的诊断；现有弃用/工具提示保留。签名、上传和元数据步骤跳过。**此 GREEN 不表示 Task 7 验收**：独立审查发现 gated A 退出后 B 被全局启动标记丢弃，正在加入行为回归。修复仅串行未完成的准入，已领取但排队中取消的请求仍由引擎结束，不引入额外录音所有者。
- [Task 7 行为 RED #169](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35527213277) **FAILURE**，准确源码 `e3cf37d8be1ea78be897867ed11edd897bd30f88`，build job 8m46s。172 单元仅两处目标失败：17:56:32Z 排队 B 未领取请求、17:56:35Z 重开 B 未同步领取请求；其余单元及 4 个独立 UI 通过，编译/环境正常。已确认全局启动标记丢失后继请求，开始模型内准入顺序最小修复；不是环境缺失或新增接口编译错误。修复不改变引擎协议、终态所有者或录音架构。
- [Task 7 GREEN #170](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35527822788) **SUCCESS**，准确源码 `faedeb69f6adcf6da045ad2070fb3a6d6a1eb081`，build job 16m56s。172 单元零失败（19.795s / 22.214s wall），模型 25/25；排队中退出/取消 1.022s、A 退出后 B 正常接续 0.601s 通过。4 个独立 UI 在两个 scheme 均通过（220.646s / 62.390s）；unsigned BUILD 18:19:38Z / ARCHIVE 18:20:23Z 成功。artifact `10609983622`（VoType-IPA，4,978,302 bytes）为无签名产物，签名、App Store Connect、元数据步骤跳过。没有点名本项变更文件的诊断，已有兼容弃用和工具提示仍保留。独立规格/质量/证据复审 PASS，Task 7 验收完成；没有把较慢但仍在运行的 CI 重启。
- Task 8 选区风险：关闭语音编辑时仍可能产生携带非空选区的普通插入结果。已把非空选区的保留/拒绝、明确复制/丢弃及一次快照校验加入测试要求；#171 的真实 UIKit 合成实验确认 `UITextView.insertText` 替换非空选区，不能仅凭 `.insertAtCursor` 名称视为无破坏。真实第三方键盘行为仍需真机验证。
- [Task 8 第一阶段 RED #171](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35529007106) **FAILURE**，准确源码 `c1dc4b0d7b8720c9e32711c6de42a34a888c13b3`，build job 9m5s。173 单元仅两处目标失败：18:31:28Z，LaunchPolicyTests 的冷路径及 1.2 秒超时路径实际返回 `openContainingApp` 而非 `showManualRecovery`，没有缺失接口或编译错误。真实 `UITextView` 选区实验 0.126s PASS，4 个独立 UI 68.074s PASS；失败后 Release/Archive/签名/分发未执行。已向同一实施者发第二阶段 TEST-ONLY GO，补齐剩余契约回归，再跑缺失接口 RED。没有改 Task 8 生产逻辑或发布新候选。
- Task 8 预检纠正回执语义：现有终态发布已写防重复 receipt；拒绝插入应保持原结果和 receipt 字节不变，不能要求 receipt 不存在。双会话迁移的拒绝检查不得调用会删过期/损坏文件的 reader。沿用真实临时 IPC 文件验证，不引入生产故障注入接口；第二次写入失败回滚分支若无法确定性触发，必须如实标为未运行。
- [Task 8 第二阶段 RED #172](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/35530072311) **FAILURE**，准确源码 `d35829f30dbb99bdc4a1785ad2b5410d60c3b7ce`，build job 55s。七个测试文件补齐 hot-ack、恢复快照/指纹、选区保护、完整结果比较、真实 IPC 迁移/回执/消费及前后台接续。环境、XcodeGen、plist 成功后，18:46:07Z 精确报缺少 `KeyboardLaunchScheduling` 与 `KeyboardLaunchScheduledTask`（三处诊断），符合缺失接口 RED；单元运行、UI、Release/Archive/分发未进入。本地 plist 2/2（0.027s）、staged diff 校验通过。已向同一实施者发生产 GO，尚无 Task 8 GREEN 或验收结论。
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
