# Tapito 开源首页调研与整理

日期：2026-10-21。范围为 README 与贡献／演示文档；不代表仓库已公开，不包含发布、推送或重新许可。

## 参考了什么

| 官方来源 | 值得借鉴的做法 | 在 Tapito 中的取舍 |
| --- | --- | --- |
| [Browser Use](https://github.com/browser-use/browser-use) | 首屏说明产品，给出真实任务演示，按使用方式组织快速开始，进阶内容交给文档与 FAQ | 先给用户任务示例与上手路径；不照搬云产品、营销指标或尚未录制的演示 |
| [Open-AutoGLM](https://github.com/zai-org/Open-AutoGLM) | 自然语言任务解释手机 Agent，设备准备、运行配置与操作示例相连，并提供中英文入口 | 解释“模型决策 → 操作 → 观察”；把 iPhone 开发者模式、签名、配对与模型要求写清楚 |
| [SideStore](https://github.com/SideStore/SideStore) | 对依赖设备环境的 iOS 项目，明确环境要求、模块作用、构建贡献入口与上游来源 | 不把安装成功等同连接成功；保留 VPN/开发者服务边界及 Actell 来源 |
| [GitHub README 指南](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes) | 回答项目做什么、为何有用、如何开始、如何获得帮助；使用仓库相对链接 | 首页覆盖这条阅读路径，架构细节和贡献规范分层组织 |

以上为结构与信息组织参考，没有复制对方的营销文字、演示素材或性能数据。

## 本次发现与修改

- 原首页技术信息齐全，但缺少从用户任务到首次上手的阅读顺序。增加任务示例、先决条件、配置步骤、常见问题和文档导航。
- 原架构图片仍写“Jev OCR · 试验”“Jev 当前不接入自动学习”，与当前共享主 Agent 的实现不符。先校正架构／执行关系，随后按用户要求使用 image2 生成中英双语 v4 图片并接入首页；旧素材保留在原处。最终图片及生成、纠错提示词见[图表记录](assets/tapito-diagram-prompts-v4.md)。
- 根据 `HarnessAgentEngine`、`JevScreenExecutor`、`WorkflowPrompts` 及 `Tapito-JEV-OCR.md`，明确 Jev 接收阶段目标和准确字段值，交回阶段结果，由主 Agent 核验完整任务。
- 区分本机 OCR、远程推理、显式截图、密钥存储与异步学习；不把“本机识别”写成“所有数据离线”。
- 区分技能指南、参考位置与审核后的可执行能力；不承诺一次操作便永久免 OCR。
- 取消过时的“闭源商业版本”为当前目标的表述，保留历史审计与现有 LICENSE、来源和依赖声明。
- 新增贡献指南与录屏指南；中英文首页使用相同结构和事实口径。

## 本地核对依据

- [工程配置](../ios-app/project.yml)与[生成器](../ios-app/scripts/generate_xcode_project.py)：iOS 27、主 App／扩展、签名配置与 Rust 构建。
- [供应商存储](../ios-app/Tapito/Storage/ProviderStore.swift)与[密钥存储](../ios-app/Tapito/Security/SecretStore.swift)：主模型绑定、Jev 配置及 Keychain。
- [Jev 当前实现文档](Tapito-JEV-OCR.md)与[运行时契约](Tapito-WORKFLOW-RUNTIME.md)：共享循环、工具结果、阶段交回与学习职责。
- [内置技能](../ios-app/Tapito/BuiltinSkills/)与[连接文档](Tapito-CONNECTION.md)：App 指南、通用能力、初始化和系统限制。
- [来源记录](../THIRD_PARTY.md)与[LICENSE](../LICENSE)：当前许可及复用范围。

## 后续需要真实素材的部分

用户后续补充真机录屏。优先完成读取任务、整段文字输入和学习复用三个例子，拍摄要求见[录屏指南](Tapito-DEMO-GUIDE.md)。不添加尚不存在的下载、CI 通过、性能提升或成功率徽章。

README 整理不等于完成开源发行审计。仓库是否公开、待发布文件与资源范围、历史材料中是否含私人数据，仍需在实际发布前单独核对。
