# Tapito iOS 工程

当前入口说明。产品架构见[项目 README](../README.zh-CN.md)，Agent 可执行契约见[程序工作流](../docs/Tapito-WORKFLOW-RUNTIME.md)，连接步骤见[连接模块与户外初始化](../docs/Tapito-CONNECTION.md)。旧测试日期和上游技术实验不作为当前功能说明。

## 工程与模块

- 最低 iOS 27，使用 Xcode 27；工程、scheme 和主 target 为 `Tapito`。
- 主 App：`com.y175.tapito`；URL scheme：`tapito`。
- VPN 扩展：`TapitoLoopbackTunnel` / `com.y175.tapito.LoopbackTunnel`。
- 实时活动扩展：`TapitoLiveActivity` / `com.y175.tapito.LiveActivity`。
- `TapitoAgentKit`：会话、程序编排、工具调度、页面能力、记忆与异步学习。
- `ProviderKit`：模型契约、Chat Completions / Responses 适配。
- `TapitoConnectionKit`：连接配置、回环数据包、户外初始化；`../ncm-dev/TapitoNCM` 与 Rust 后端处理开发者服务协议。
- `TapitoVoiceKit`：语音状态与音频适配。
- `Tapito/Agent/AgentSessionController.swift` 是 iOS 组合根；`AgentPresentationAdapter` 将核心事件转换为 UI 展示。

主 App 默认走 VPN 回环，设置中保留 ESP32 NCM 模式；普通聊天不要求设备连接。旧 ScreenCaptureKit/USB HID/TLS 实验源码不代表默认执行路线。

## Agent 正式执行路径

正式入口使用 `WorkflowAgentEngine`，不是由 UI 逐轮决定下一步。

1. M1 产出结构化任务；程序校验路由、供应商、技能及能力版本。
2. 程序解析已安装 App，准备对应技能；当前屏幕任务不启动其他 App。
3. 已审核页面序列通过本机画面核验后执行；未知页面走本地 OCR 与有预算的模型/Tool Call 探索。
4. 工具批次完整预检、串行执行并提交回执；输入后程序重新观察。页面偏离可纠正剩余步骤，协议错误或动作结果未知直接停止。
5. 回复完成后入队 M6/M7 分析；个人记忆和页面知识独立、可管理，不阻塞当前任务返回。

当前主链上限 32 次模型请求，每批最多 16 个工具，页面序列最多 16 段，观察纠错最多 2 次。页面/控件知识保存稳定 UI 元素与操作证据，动态内容和业务结果仍需当次核实；没有“所有步骤永久不截图或不 OCR”的保证。

内置 `ios-operation`、`ios-notes`、`ios-clock`、`wechat`、`weibo`、`qq` 技能由程序按任务装配。提示词的实际来源为 [WorkflowPrompts.swift](TapitoAgentKit/Sources/TapitoAgentSwiftAgentKit/WorkflowPrompts.swift)。模型接入、固定版本、纠错和学习规则以该代码及[运行文档](../docs/Tapito-WORKFLOW-RUNTIME.md)为准。

## 语音与系统入口

- 支持文字、“执行任务” App Intent、快捷指令、“开始语音任务”和操作按钮控制。
- 系统“控制”可绑定 `Tapito 语音任务`；初次配置和权限授予仍需用户操作。
- 执行手机任务时释放麦克风与音频，不接收语音打断；完成及播报后可继续聆听。
- 当前背景执行方案使用任务期间的定位运行资格；需要相应系统授权，不意味着无限后台运行。
- 实时活动显示运行状态并提供“结束语音”；灵动岛展开由系统决定，Live Activity 本身不授予后台执行资格。

## 连接配置

在“设置 → 手机操控 → 连接与验证”建立本 App 的配对身份、启用 `Tapito 本机连接` 并核验屏幕/输入能力。首次添加 VPN 需要系统确认；VPN 本身不代替开发者模式、配对或 DDI 准备。

内置 VPN 仅回注配置的本机接口与对端流量，不设置外部代理节点、DNS 或互联网默认路由。外部 VPN 仍可作为显式模式使用；切换连接模式不能发生在任务执行期间。

户外初始化通过内置签名快捷指令编排“准备 → 开启飞行模式 → 离线建链 → 关闭飞行模式 → 恢复核验”。参数使用前一步的输出变量，不手填初始化编号。已有有效连接直接返回就绪。快捷指令中断后不能保证执行清理动作，必要时手动关闭飞行模式。

重签快捷指令：

```sh
python3 ios-app/scripts/build_outdoor_shortcut.py --team <Apple-Team-ID>
```

修改团队、Bundle ID 或 App Intent 参数后重新生成签名资源。完整边界见[连接文档](../docs/Tapito-CONNECTION.md)。

## 供应商与数据

设置支持多个供应商和默认供应商/模型；每轮固定所选配置。可选 OpenAI 兼容 Chat Completions 或 Responses；默认的无状态 Responses 与显式服务端响应链配置分别处理。原生工具、流结束、参数和调用 ID 校验在执行前完成。

ChatGPT 订阅配置使用独立账号/协议入口，真实账号可用性与套餐授权不能由本地 mock 测试证明；见[订阅说明](../docs/CHATGPT-SUBSCRIPTION.md)。不在源码提交 API Key、账号凭据或设备配对文件。

OCR 在本机运行，但产生的文字候选可作为上下文发送给选定模型；视觉观察会发送所选屏幕图像。历史对话、显式附件、个人记忆和页面知识是不同存储，不能把“页面模板不存动态内容”理解为“所有历史对话都不落盘”。异步学习固定入队时的供应商身份，配置变化时明确失败。

## 构建

在仓库根目录执行。Rust 需要 `aarch64-apple-ios`；仅需模拟器构建时再添加 `aarch64-apple-ios-sim`。Xcode 构建阶段生成 Rust 静态库，首次解析 Swift/Rust 依赖需要网络。

```sh
rustup target add aarch64-apple-ios
python3 ios-app/scripts/generate_xcode_project.py

xcodebuild -project ios-app/Tapito.xcodeproj -scheme Tapito \
  -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath .build/DeviceBuild \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

这只编译 App、扩展和测试，不安装也不运行测试。真机安装需配置自己的 Apple 签名团队，主 App 与 VPN 扩展须具备 `packet-tunnel-provider` 权限。更换 Bundle ID 后需要重新进行 App 配对、权限及快捷指令配置。

## 验证

```sh
# Agent 主机测试，不使用模拟器或真实模型。
swift test --package-path ios-app/TapitoAgentKit \
  --scratch-path .build/AgentCoreTests

# 按需运行现有协议测试。
CC=clang bash tools/test_usb_device.sh

# 仅在明确需要 iOS 集成/UI 验证时使用隔离模拟器。
bash ios-app/scripts/test_core.sh <isolated-simulator-UDID>
RUN_UI_TESTS=1 bash ios-app/scripts/test_core.sh <isolated-simulator-UDID>
```

2026-10-16 最近一次 Agent 验证：54 项主机测试通过、iPhoneOS `build-for-testing` 通过。iOS 适配测试完成编译，未在模拟器或真机执行；没有真实模型/设备动作或 P50/P95 耗时基准。见[完整记录](../docs/Tapito-WORKFLOW-RUNTIME.md#本轮验证)。

旧实验、归档用例及来源记录保留，入口见[归档说明](../archives/README.md)。当前 API 以源码和运行文档为准。
