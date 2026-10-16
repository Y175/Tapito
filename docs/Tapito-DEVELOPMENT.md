# Tapito 开发记录

更新：2026-10-15。工程目录 `/Users/y175/code/Tapito`。

## 全新应用命名

用户明确指定名称 Tapito，并要求不兼容旧版、不迁移历史数据。源码类型、Swift Package、工程、scheme、主 target、测试 target、后端库和运行时名称统一更名。

| 项目 | 标识 / 名称 |
| --- | --- |
| 主 App | `Tapito` / `com.y175.tapito` |
| URL scheme | `tapito` |
| VPN 扩展 | `TapitoLoopbackTunnel` / `com.y175.tapito.LoopbackTunnel` |
| 系统 VPN 配置 | `Tapito 本机连接` |
| 活动扩展 | `TapitoLiveActivity` / `com.y175.tapito.LiveActivity` |
| 操作按钮控制 | `Tapito 语音任务` |
| 户外快捷指令 | `Tapito 户外初始化` |
| 独立模块 | `TapitoConnectionKit`、`TapitoVoiceKit`、`TapitoNCM` |
| 模型工具命名空间 | `tapito` |

新 App 具有独立沙箱、Keychain 服务标识、配置键和系统授权。首次使用需配置模型、在新 App 内配对、授权 VPN / 语音 / 定位、添加新快捷指令并绑定新控制。旧 App 与用户已导入的旧快捷指令不被删除或修改。

户外快捷指令必须使用新 Bundle ID 重新生成与签名；初始化编号、离线回执、结果的三个文本变量绑定保持不变。登录回调页面的 Content-Length 改为根据 UTF-8 正文实际字节数生成。

## 构建与验证

本次全局更名已完成。保留扁平「鼠标点击黑洞」图标，不更改任务、连接或语音运行逻辑。

- 主机测试全部通过：连接模块 15 项、语音模块 18 项、Rust 后端 52 项、协议依赖 176 项、USB/TCP 合约 25 项。
- 户外快捷指令重新生成并签名；三个 App Intent 指向 `com.y175.tapito`。Apple 本机解析器确认初始化编号、离线回执和显示结果的文本变量绑定无损往返。
- 374 个源码/配置文件扫描通过；运行源码、模块路径、配置和本地化资源无旧产品名，plist 与字符串目录可解析。许可证和第三方署名保留。
- iPhoneOS `build-for-testing` 成功：App、实时活动扩展、VPN 扩展及测试 target 全部编译通过，未运行 iOS 测试。
- 构建产物核对通过：主 App 与两个扩展的 Bundle ID 和显示名、中文和英文名称、`tapito` URL scheme、Intent 元数据与签名快捷指令文件一致性。
- 未签名产物：`.build/TapitoDevice/Build/Products/Debug-iphoneos/Tapito.app`。本轮未安装、未启动模拟器或执行真实手机任务。

证据位于 `.build/tapito-rename/`：模块与协议测试日志、`shortcut-parser.log`、`brand-audit.json`、`iphoneos-build.log`、`Build.xcresult`、`built-product-audit.json`。修改前的源码副本、工作区差异和路径清单也保存在该目录。

```sh
python3 ios-app/scripts/generate_xcode_project.py
python3 ios-app/scripts/build_outdoor_shortcut.py --team <Apple-Team-ID>
swift test --package-path ios-app/TapitoConnectionKit --scratch-path .build/tapito-validation/connection
swift test --package-path ios-app/TapitoVoiceKit --scratch-path .build/tapito-validation/voice
bash tools/test_ncm_rust.sh
CC=clang bash tools/test_usb_device.sh
xcodebuild -project ios-app/Tapito.xcodeproj -scheme Tapito \
  -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath .build/TapitoDevice CODE_SIGNING_ALLOWED=NO build-for-testing
```

## Agent 重构与长期记忆调研

2026-10-15 已完成当前 Agent 装配、会话、技能和执行检查点的源码核查，并调研 AgentScope、LangGraph/LangMem、Letta、Mem0、AppAgentX、Agent S 与 Open-AutoGLM 官方资料。模块边界、长期记忆管理、专属技能与自学习验证方案见 [Agent 架构调研与实施顺序](Tapito-AGENT-ARCHITECTURE-RESEARCH.md)。该文件为设计建议；本轮仅更新文档，尚未新增 Agent 包或变更运行逻辑。

## Agent 核心与长期记忆实现

2026-10-15 后续开发已接入独立 `TapitoAgentKit`：实际模型循环与事件转换从原 ViewModel 抽离；新增持久偏好/任务摘要、带修订检查的管理入口、五个 App 专属技能和带屏幕文字证据的流程修订候选。候选经用户审核后下一任务生效，可停用或回退。UI 只消费中立事件，iOS 连接/后台/音频职责留在平台装配层。13 项主机测试通过，iPhoneOS App 与现有测试目标 build-for-testing 成功；本轮未安装或启动模拟器，尚未执行新的真机验收。详见 [当前 Agent 模块实现及验证](Tapito-AGENT.md)。

## 历史证据

此前的构建与安装证据分别见 [前次命名验证](../archives/history/TapPilot-DEVELOPMENT-2026-10-15.md) 和 [早期开发记录](../archives/history/ORVA-DEVELOPMENT-2026-10-15.md)。历史原文中的名称和绝对路径表示当时版本，不代表本次 Tapito 构建结果。

## 2026-10-15 可执行流程学习

核心包新增 WorkflowExecutor、WorkflowDevice、WorkflowLibrary；App 接入真实操作轨迹与本机像素比对；模型新增 list_workflows/run_workflow/name_workflow；设置增加流程与队列管理。没有更改连接、后台定位、麦克风或语音打断机制。详细语义、使用方式和验证边界见 [Agent 模块](Tapito-AGENT.md)。本轮不安装、不运行模拟器、不操作真机。

最终验证：26 项主机测试通过；iPhoneOS build-for-testing 成功。日志在 `.build/workflow-refactor/`。
