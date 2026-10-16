# ORVA 连接模块与户外初始化

本轮将本机回环 VPN、户外初始化编排与现有配对后端连接起来。UI 与 Agent 重构时，通过已有接口调用连接服务，无需重写回环数据包处理或户外状态机。

## 手机使用

1. 保留已有的手机配对身份，先确认开发者模式、DDI、本地网络授权已准备好。内置 VPN 不负责替代首次配对或准备 DDI。
2. 打开 ORVA「设置 → 手机操控 → 连接与验证」，在「ORVA 连接准备」点击「启用 ORVA 内置 VPN」，确认系统添加 VPN 配置。此操作可能替换当前运行的 VPN；不会代理到外部节点。
3. 在 ORVA「设置 → 后台执行」按现有 A 方案完成“始终”定位授权。初始化只在建链期间持有独立执行凭据，不保存位置，不使用麦克风或播放音频。
4. 点击「添加户外初始化快捷指令」，通过分享菜单导入签名文件；如果没有快捷指令入口，先存储到“文件”，再打开该 `.shortcut` 文件并确认添加。首次导入界面仍需手机端验收。
5. 户外仅蜂窝网络时，保持手机解锁，运行「ORVA 户外初始化」。完成后再发起任务。这里不自动开始录音或执行 Agent 任务。

已有可验证的操控连接会直接返回就绪，不切换飞行模式。未连接时顺序是：启动内置 VPN → 系统快捷指令打开飞行模式 → 等待蜂窝与 Wi-Fi 均离线并建立操控连接 → 系统快捷指令关闭飞行模式 → 检查网络恢复、VPN 和同一操控连接。

系统可能记住飞行模式中的 Wi-Fi 状态；若 Wi-Fi 仍在线，离线检查会明确失败，不冒充仅 5G 初始化成功。请在户外验证前自行关闭 Wi-Fi。

普通建链失败作为结构化回执返回，让下一条系统动作先关闭飞行模式，再报告错误。如果用户中途停止快捷指令或系统终止进程，后续动作无法保证执行，需要自行关闭飞行模式。App 不通过私有 API 控制无线开关，也不定时重试或重放输入。

## 模块边界

| 模块 | 职责与依赖 |
| --- | --- |
| `ios-app/ORVAConnectionKit` | 纯 Swift 配置校验、IPv4 回注、初始化状态机。依赖 Foundation，不依赖 SwiftUI、Agent、语音或 NetworkExtension。 |
| `ORVALoopbackTunnel` | 独立 Network Extension；仅处理配置接口与对端之间的 IPv4 流量，不配置 DNS、外部代理服务器或互联网默认路由。 |
| `EmbeddedLoopbackVPN` | 使用 NetworkExtension 管理 ORVA 自己的配置；首次配置在前台由用户确认，后台仅启动已批准且匹配的配置。 |
| `DeviceConnectionServices` | 组合根；将 VPN、现有 PairingFlow、独立 A 方案执行凭据与物理网络检查注入状态机。 |
| `OutdoorConnectionIntents` | 三个后台 App Intent：准备、离线建链、恢复后验证。只有参数和结果转换，不包含连接算法。 |
| `ConnectionSetupSection` | 可替换的 SwiftUI 设置入口，负责呈现状态与用户操作。 |

核心接口为 `LoopbackTunnel`、`PairedControlConnection`、`ConnectionExecutionLifetime`。现有底层后端仍由 PairingFlow 管理，配对身份和控制协议不复制到新模块。将来更换 UI 只需保留调用连接服务的入口；更换 Agent 仍复用既有控制通道；更换底层连接后端时实现 `PairedControlConnection` 适配器。

初始化 UUID 同时作为占用票据；每次异步返回后核对所属初始化，防止旧回调影响新流程。初始化与 Agent 控制任务互斥。过期、取消、执行权限撤销会释放本次占用，失败不会自动重连、重配或重放动作。成功后保留原连接，释放初始化执行凭据。

## 生成与配置

- 默认接口/对端为 `10.7.1.1` / `10.7.0.1`，由连接设置传入；严格验证 IPv4 和配置版本。配置改变后需要重新配置自己的 VPN，地址不匹配会明确报错。
- App Bundle ID：`com.y175.orva`；VPN 扩展：`com.y175.orva.LoopbackTunnel`。App 与扩展都需要 `packet-tunnel-provider` 签名权限。
- 正式启用前，外部 VPN 模式保持原样。切回「改用外部 VPN」会停止 ORVA 的 VPN，不清除配对身份。
- 快捷指令源生成器：`ios-app/scripts/build_outdoor_shortcut.py`。执行 `python3 ios-app/scripts/build_outdoor_shortcut.py --team <Apple-Team-ID>`，使用 Apple `shortcuts sign` 生成可分享的签名文件。更换应用 Bundle ID、团队或 Intent 参数时须同步生成器并重新签名。
- 签名文件随 App 放入 `ConnectionResources`，无需在线下载；系统仍要求用户主动添加。
- Xcode 工程由 `ios-app/scripts/generate_xcode_project.py` 生成；包含新 Swift Package、扩展、嵌入依赖和资源。Network Extension 为独立实现，未复制 LocalDevVPN 源码。

## 验证记录（2026-10-15）

- 连接核心 15 项测试通过：配置、包校验、数据回注与校验和、初始化成功/失败、已有连接复用、网络未切换/未恢复、重复/外来回执、超时与旧回调隔离。
- App 核心 469 项测试通过，包含现有授权、会话隔离及未知结果不重放覆盖。使用独立临时模拟器，测试后关闭。
- iPhoneOS 无签名及签名构建成功；App 和嵌入 VPN 扩展深度签名校验通过，描述文件包含 Network Extension 权限；三个 Intent 的编译元数据与参数、包内快捷指令文件已核对。
- 通过无线连接安装到 175phone 成功，Bundle ID `com.y175.orva`，安装序列 `2496`。安装不是首次 VPN 授权、快捷指令导入或完整户外建链成功的证明；本轮未代用户切换飞行模式或执行真实任务。
- 本机证据：`.build/connection/core-tests.log`、`unsigned-build.log`、`signed-build.log`、`app-tests-summary.log`、`175phone-install.json`；App 测试结果 `.build/validation/core.7S5mnM/Tests.xcresult`。

用户此前验证过手动飞行模式建链后恢复 5G 可用；新的内置 VPN 与自动快捷指令组合需要分别验收首次添加、Wi-Fi 建链、仅 5G 初始化、重复调用、普通协议失败后网络恢复和手动中止后的恢复。核心测试与模拟器不证明真机 Network Extension 或蜂窝路由表现。

## 快捷指令文本变量修正（v2，2026-10-15）

手机导入 v1 后，`ticket`、`receipt` 和显示结果的 `Text` 参数变成空白。原因是三个文本参数错误使用 `WFTextTokenAttachment`，而文本参数需要 `WFTextTokenString`，用 U+FFFC 和 `attachmentsByRange` 嵌入输出引用。条件动作的整个输入选择器仍使用附件形式，两种参数不能混用。

v2 修正三个字段，签名前验证其格式、上游 UUID 与飞行模式恢复顺序。`validate_outdoor_shortcut.m` 是仅在 Mac 上运行的开发检查，不打包进 App：调用本机 Apple 快捷指令文本解析器，确认旧形式返回空状态，而新形式完整保留变量并能无损序列化。它不导入或执行快捷指令、不修改快捷指令库、不控制无线开关；私有主机检查 API 不属于 ORVA 运行依赖。

```sh
python3 ios-app/scripts/build_outdoor_shortcut.py --team 89AYSXVVZ3
xcrun clang -framework Foundation ios-app/scripts/validate_outdoor_shortcut.m \
  -o .build/connection/validate_outdoor_shortcut
.build/connection/validate_outdoor_shortcut .build/connection/ORVA-Outdoor.unsigned.shortcut
```

本次三处文本变量均通过 Apple 解析器验证；9 个缺失、旧格式或错误上游引用样本被签名前校验拒绝。Intent 参数名称与编译元数据一致。没有重复运行与本次资源修正无关的模拟器或 469 项 App 核心测试。手机上已导入的副本不会被 App 更新自动覆盖，用户手动修好的副本可继续使用；需更新模板时重新导入并确认替换。修正后手机重新导入的界面仍需单独确认。

v2 无签名/签名构建与深度签名校验通过；包内快捷指令与重新签名的 v2 源文件逐字节一致。无线安装 175phone 成功，安装序列 `2504`。证据：`.build/connection/shortcut-v2-parser.log`、`shortcut-v2-unsigned-build.log`、`shortcut-v2-signed-build.log`、`shortcut-v2-install.json`。
