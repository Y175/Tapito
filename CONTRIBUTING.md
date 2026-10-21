# Contributing to Tapito / 参与贡献

Thanks for helping make Tapito useful on real devices. 中文或英文的问题报告与 PR 都欢迎。

Start with the [English README](README.md) or [中文 README](README.zh-CN.md). Both describe the current setup; dated design documents may describe earlier implementations.

## Useful contributions / 欢迎贡献的内容

| Area | What helps / 有帮助的贡献 |
| --- | --- |
| App skills | Document a page's stable controls, meanings and observed outcomes. 补充页面识别、控件功能、适用条件和操作结果。 |
| Reproducible failures | Share a small task and the first incorrect step. 提供最小任务、首个错误步骤与经过脱敏的证据。 |
| Runtime and providers | Improve tool contracts, cancellation, model adapters or diagnostics. 保持 Agent 与 UI、连接层的职责边界。 |
| Documentation | Improve setup, translations and real-device demonstrations. 中英文首页请同步修改。 |

## Report a problem / 报告问题

Use [GitHub Issues](https://github.com/Y175/Tapito/issues). Include:

1. **Version / 版本：** Tapito commit or build, iOS version, iPhone model and target app version.
2. **Mode / 模式：** Normal agent or Jev collaboration; provider/model names, without credentials. Jev reports should also identify the main model.
3. **Task / 任务：** The smallest reproducible request, expected result and actual result.
4. **First incorrect step / 首个异常步骤：** Tool/model step name, measured duration, error and relevant frame/receipt details. Distinguish “not sent” from “possibly executed.”
5. **Evidence / 证据：** A redacted screenshot or recording, plus the relevant diagnostic excerpt. State whether the issue reproduces and whether the connection verification passed.

Remove API keys, tokens, pairing identities, contact names, chat contents and unrelated screen data before posting. Do not upload an entire app container or raw diagnostic archive. If a suspected security issue cannot be described without sensitive material, do not post that material in a public issue.

公开前请脱敏，保留定位问题所需的步骤和错误即可；不要上传完整应用容器、配对文件或未经检查的日志包。

## Change an app skill / 完善 App 技能

Skills live in [`ios-app/Tapito/BuiltinSkills/`](ios-app/Tapito/BuiltinSkills/). Keep `ios-operation` general; put app-specific behavior in the relevant app directory and longer page guides in `references/`.

For each page/control, record:

- App/version, page identity and stable labels; identify the source of the observation.
- Control purpose, how to distinguish repeated labels, and any layout/keyboard/overlay conditions.
- The expected page or state after the action, and how to verify it.
- Which statements are observed, documented by the app vendor, or still unconfirmed.

页面指南可以给出有来源的参考位置，但不能把旧截图坐标直接当作当前点击依据。联系人、消息、榜单条目和输入内容不属于可复用的 UI 骨架。不要把单次成功写成所有版本通用的能力，也不要让缺少专属技能成为禁止操作 App 的理由。

An illustrative coordinate is not a reviewed executable workflow. Learned operations require the runtime's current-frame checks and review path. See the [runtime contract](docs/Tapito-WORKFLOW-RUNTIME.md).

## Make a change / 提交修改

- Keep the change focused. Explain the concrete problem, resulting behavior and affected layer.
- Preserve the distinction between the main agent's task decision, Jev's stage selection, and actual device execution.
- Expose protocol/configuration errors through existing error handling. Do not hide them by replaying inputs, guessing a different target or silently changing providers.
- Keep secrets and local signing material out of the repository. Preserve source attribution and third-party license notices.
- For a new behavior, add or update a meaningful test at its boundary. Documentation-only changes need link/content checks, not an iPhone build.

按修改范围运行验证；以下命令都从仓库根目录执行：

| Changed area | Verification |
| --- | --- |
| Agent / Jev orchestration | `swift test --package-path ios-app/TapitoAgentKit --scratch-path .build/AgentCoreTests` |
| OCR selection | `bash ios-app/scripts/test_ocr_selection.sh` |
| Connection core | `swift test --package-path ios-app/TapitoConnectionKit --scratch-path .build/ConnectionTests` |
| Voice state machine | `swift test --package-path ios-app/TapitoVoiceKit --scratch-path .build/VoiceTests` |
| App / platform integration | The `xcodebuild … build-for-testing` command in the README, plus a relevant real-device case when available |

In a pull request, state what changed, why, what was actually tested and what remains unverified. A host test, an unsigned build and a successful real-device task are different evidence. Do not report one as another.

PR 请说明问题、修改后的行为、实际验证结果和未验证部分。涉及 UI 时附截图；涉及运行流程时附最小任务和必要的脱敏回执。无需为了展示效果而执行真实付款、群发或其他无关操作。

## License / 许可

Changes must be compatible with the repository's [LICENSE](LICENSE) and existing per-file notices. Identify the source and license of any reused code or assets, and update [THIRD_PARTY.md](THIRD_PARTY.md) when needed.
