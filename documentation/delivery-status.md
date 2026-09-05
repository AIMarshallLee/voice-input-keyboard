# VoType 持续交付台账

更新：2026-09-05。仅记录经过核对的事实；未提交工作不计入已合并实现。

## 当前目标与断点

- 目标：按已确认商用 V1 规格完成可靠、简洁的语音键盘；当前只执行 Slice A。
- 职责机制：[窗口 Agent 规划书](../docs/superpowers/specs/2026-09-05-votype-continuous-delivery-agent-charter.md)，用户已回复“同意”。
- 规格：[商用 V1](../docs/superpowers/specs/2026-09-04-voice-first-commercial-v1-design.md)。
- 实施计划：[Slice A 九任务](../docs/superpowers/plans/2026-09-04-slice-a-reliable-session-engine.md)。
- 当前断点：Task 1 已取得真实 RED，契约/IPC 最小实现已就绪。正在准备 macOS GREEN，实施验收进度仍为 **0/9**。
- 下一动作：推送 Task 1 实现到同一 PR 运行 macOS 回归，并进行独立任务审查。

## 源码与工作区身份

- 主仓库：`D:\Obsidian\voice-input-keyboard`
- 唯一实施工作树：`D:\Obsidian\voice-input-keyboard\.worktrees\slice-a`
- 当前分支：`codex/slice-a-reliable-session-engine`
- 实施基线：`a5045f21286ec831170c93f7321a57ec346b57c6`；linked worktree 已建立。原始 checkout 保持规划分支，不并行修改业务代码。
- 原有规格、实施计划、职责稿与台账已在授权后提交为 `a5045f2`；没有丢弃原差异。
- 草稿 [PR #13](https://github.com/AIMarshallLee/voice-input-keyboard/pull/13) 已创建，未合并。
- `project.yml` 是生成工程的唯一来源；现有测试 target 包含整个 `VoTypeTests` 目录。
- 实施前 Task 1 预检确认 SessionToken/EditPlan/typed commit 缺失；现已添加最小实现，等待测试与审查。新测试通过 `xcodegen generate` 编入。

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
| 1 | Canonical Session 与向后兼容 IPC | 进行中：RED 已确认，实施待 GREEN/审查 |
| 2 | 依赖端口与同步音频屏障 | 待做，依赖 Task 1 |
| 3 | 引擎主路径与命令语义 | 待做 |
| 4 | 截止时间、迟到回调、竞态与重用 | 待做 |
| 5 | Apple、文本、Darwin 生产适配 | 待做 |
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
- [Task 1 RED #150](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/33952943674)，源码 `b15505687c3054b7a008c264e3a0534fbc2af0bf`：Unit/UI 编译按预期失败，缺少 SessionToken/EditPlan/commit/peek/cancel notification/fingerprint。测试已先于生产实现提交；新实现 GREEN 尚未运行。
- 真机语音/跨 App/权限/PiP：**EXTERNAL / NOT_RUN（本轮）**。历史用户测试曾暴露缺陷，不抹去历史结果。

## 发布基线

- 历史分发：1.0 (146)，源提交 `01b3db482fb25821e8f4281ee66a3a8991e9051e`；processing/Internal Testers 证据见 [版本报告](releases/1.0-build-146-testflight.md)。不是 Slice A 新产物或完整真机通过证据。
- 实施前最新已核对成功普通构建为 [Build IPA #148](https://github.com/AIMarshallLee/voice-input-keyboard/actions/runs/33803082411)，源码 `ba3ca0e`，不是新 TestFlight 上传。新基线检查见上文。
- 本轮 PR #149 已生成自动化构建及无签名归档；尚无新签名、TestFlight processing 或分发结果，不将 PR 产物称为已发布版本。

## 阻塞与恢复

| 缺口 | 责任方/解除条件 | 解锁后首动作 |
|---|---|---|
| 本机无 Apple 测试运行时 | Git/PR CI 已明确获准，使用现有 macOS 流水线；不再是授权阻塞 | 建立基线后提交 Task 1 失败测试并实施 |

此前的 Git/CI 授权阻塞已解除；继续实际实施，不通过改写验收标准或假造 Windows 测试结果绕开门禁。
