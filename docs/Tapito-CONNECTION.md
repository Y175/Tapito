# Tapito 连接模块与户外初始化

本轮将本机回环 VPN、户外初始化编排与现有配对后端连接起来。UI 与 Agent 重构时，通过已有接口调用连接服务，无需重写回环数据包处理或户外状态机。

## 手机使用

1. Tapito 是全新 App：先在 Tapito 内建立配对身份，确认开发者模式、DDI、本地网络授权已准备好。内置 VPN 不负责替代首次配对或准备 DDI。
2. 打开 Tapito「设置 → 手机操控 → 连接与验证」，在「Tapito 连接准备」点击「启用 Tapito 内置 VPN」，确认系统添加 VPN 配置。此操作可能替换当前运行的 VPN；不会代理到外部节点。
3. 在 Tapito「设置 → 后台执行」按现有 A 方案完成“始终”定位授权。初始化只在建链期间持有独立执行凭据，不保存位置，不使用麦克风或播放音频。
4. 点击「添加户外初始化快捷指令」，通过分享菜单导入签名文件；如果没有快捷指令入口，先存储到“文件”，再打开该 `.shortcut` 文件并确认添加。首次导入界面仍需手机端验收。
5. 户外仅蜂窝网络时，保持手机解锁，运行「Tapito 户外初始化」。完成后再发起任务。这里不自动开始录音或执行 Agent 任务。

已有可验证的操控连接会直接返回就绪，不切换飞行模式。未连接时顺序是：启动内置 VPN → 系统快捷指令打开飞行模式 → 等待蜂窝与 Wi-Fi 均离线并建立操控连接 → 系统快捷指令关闭飞行模式 → 检查网络恢复、VPN 和同一操控连接。

系统可能记住飞行模式中的 Wi-Fi 状态；若 Wi-Fi 仍在线，离线检查会明确失败，不冒充仅 5G 初始化成功。请在户外验证前自行关闭 Wi-Fi。

普通建链失败作为结构化回执返回，让下一条系统动作先关闭飞行模式，再报告错误。如果用户中途停止快捷指令或系统终止进程，后续动作无法保证执行，需要自行关闭飞行模式。App 不通过私有 API 控制无线开关，也不定时重试或重放输入。

## 模块边界

| 模块 | 职责与依赖 |
| --- | --- |
| `ios-app/TapitoConnectionKit` | 纯 Swift 配置校验、IPv4 回注、初始化状态机。依赖 Foundation，不依赖 SwiftUI、Agent、语音或 NetworkExtension。 |
| `TapitoLoopbackTunnel` | 独立 Network Extension；仅处理配置接口与对端之间的 IPv4 流量，不配置 DNS、外部代理服务器或互联网默认路由。 |
| `EmbeddedLoopbackVPN` | 使用 NetworkExtension 管理 Tapito 自己的配置；首次配置在前台由用户确认，后台仅启动已批准且匹配的配置。 |
| `DeviceConnectionServices` | 组合根；将 VPN、现有 PairingFlow、独立 A 方案执行凭据与物理网络检查注入状态机。 |
| `OutdoorConnectionIntents` | 三个后台 App Intent：准备、离线建链、恢复后验证。只有参数和结果转换，不包含连接算法。 |
| `ConnectionSetupSection` | 可替换的 SwiftUI 设置入口，负责呈现状态与用户操作。 |

核心接口为 `LoopbackTunnel`、`PairedControlConnection`、`ConnectionExecutionLifetime`。现有底层后端仍由 PairingFlow 管理，配对身份和控制协议不复制到新模块。将来更换 UI 只需保留调用连接服务的入口；更换 Agent 仍复用既有控制通道；更换底层连接后端时实现 `PairedControlConnection` 适配器。

初始化 UUID 同时作为占用票据；每次异步返回后核对所属初始化，防止旧回调影响新流程。初始化与 Agent 控制任务互斥。过期、取消、执行权限撤销会释放本次占用，失败不会自动重连、重配或重放动作。成功后保留原连接，释放初始化执行凭据。

## 生成与配置

- 默认接口/对端为 `10.7.1.1` / `10.7.0.1`，由连接设置传入；严格验证 IPv4 和配置版本。配置改变后需要重新配置自己的 VPN，地址不匹配会明确报错。
- App Bundle ID：`com.y175.tapito`；VPN 扩展：`com.y175.tapito.LoopbackTunnel`。App 与扩展都需要 `packet-tunnel-provider` 签名权限。
- 正式启用前，外部 VPN 模式保持原样。切回「改用外部 VPN」会停止 Tapito 的 VPN，不清除配对身份。
- 快捷指令源生成器：`ios-app/scripts/build_outdoor_shortcut.py`。执行 `python3 ios-app/scripts/build_outdoor_shortcut.py --team <Apple-Team-ID>`，使用 Apple `shortcuts sign` 生成可分享的签名文件。更换应用 Bundle ID、团队或 Intent 参数时须同步生成器并重新签名。
- 签名文件随 App 放入 `ConnectionResources`，无需在线下载；系统仍要求用户主动添加。
- Xcode 工程由 `ios-app/scripts/generate_xcode_project.py` 生成；包含新 Swift Package、扩展、嵌入依赖和资源。Network Extension 为独立实现，未复制 LocalDevVPN 源码。

## 验证边界

本次更名的构建与检查见 [Tapito 开发记录](Tapito-DEVELOPMENT.md)。旧版连接与快捷指令测试保留在[历史记录](../archives/history/ORVA-CONNECTION-2026-10-15.md)，不能当作新 Bundle ID 的安装或授权验收。
