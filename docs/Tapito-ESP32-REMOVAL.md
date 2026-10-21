# ESP32 连接模块移除

2026-10-16：Tapito 仅保留本机 VPN 回环作为真实设备控制通道。普通聊天与离线演示不要求设备连接。

## 移除范围

- 设置中的 ESP32 NCM 选择器、硬件连接入口及旧模式持久化读取。
- PA3 USB HID、旧 TLS Host 桥接、硬件心跳和与该路径绑定的 ScreenCaptureKit 采集/后台上下文；同时移除 `screen-capture` 后台模式。
- ESP32 NCM 服务发现、以太网固定地址绑定、NR1/NL1 中继及硬件专用 C ABI/Lockdown 入口。
- `firmware/`、`firmware-device/`、`ncm-dev/firmware/`、`ncm-dev/core/`、硬件 ProbeApp、专用固件测试和 ESP-IDF 构建脚本的版本控制源码。
- 对应的测试用例、旧协议夹具、界面字符串与失效构建引用。

## 保留边界

- `TapitoConnectionKit`、内置 VPN 扩展、系统配对身份和户外初始化快捷指令。
- `DeviceConnection/PairingFlow.swift` 与连接设置界面；它们从旧 `ESP32Control` 目录迁出，仅使用 VPN 回环。
- `NCMDeviceBridge`、`TapitoNCM` 和 Rust CoreDevice 后端仍为现有 VPN 提供认证、视频解码、截图、应用启动、文字输入及触控。这些共享协议名称不表示仍支持 ESP32。
- 会话失效、未知输入结果不重试、授权与停止释放逻辑；任务期间定位后台执行能力。
- Agent 运行、工具调用和学习诊断改用独立的 `ControlDiagnosticsLog`，不再依赖 USB 客户端。
- 来源/许可证与历史文字证据保留；移除硬件不代表完成闭源许可迁移。忽略的本地构建产物没有作为源码提交或清除。

跨语言测试从“Swift → Rust → C 硬件中继 → 合成设备”改成“Swift → Rust → 本地合成设备”，保留实际配对失败分类和取消关闭连接的验证，不连接手机。

## 本轮验证

| 验证 | 结果 |
| --- | --- |
| Agent 模块主机测试 | 54 项通过 |
| 连接模块主机测试 | 15 项通过 |
| Rust 后端测试 | 44 项通过 |
| idevice 协议库测试 | 176 项通过 |
| Swift/C ABI/Rust 合成对端与解码测试 | 30 项通过 |
| iPhoneOS `build-for-testing` | App、VPN/灵动岛扩展与测试目标编译通过 |
| 源码检查 | 当前 Xcode Swift 语法解析、工程/plist/安全断言通过 |

主机测试合计 319 项；未运行模拟器或真机集成测试，未安装、未推送。本轮不能据此宣称真机端到端行为已重新验收。

构建/测试日志位于本地 `.build/esp-removal-*.log`，不入库。
