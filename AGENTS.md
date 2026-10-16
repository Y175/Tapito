# 项目命名

- 工程与产品统一命名为 **Tapito**。上游 Actell / 执言的许可证、署名及历史记录保留原貌。
- 用户于 2026-10-15 明确要求按全新 App 更名，不做旧版兼容或数据迁移。工程、scheme 和主 target 为 `Tapito`，Bundle ID 为 `com.y175.tapito`，URL scheme 为 `tapito`；连接、语音模块与系统入口均使用 Tapito 名称。文档路径、链接和构建命令必须与实际工程一致。
- 中英文 README 同步维护
- Git 仓库按 Tapito 当前源码建立全新初始提交，不导入 Actell 或旧 Tapito 的提交图；继续保留源码来源、许可证与第三方署名。README 只描述当前模块与已实现流程，不拼接上游历史产品说明。
- 用户已于 2026-10-14 明确要求“直接装到真机”，授权构建、签名并安装到 175phone（iPhone 18 Pro）。不得把这项授权扩展到其他设备或真实任务执行。开发约定与验证状态见 `docs/Tapito-DEVELOPMENT.md`。

# 阅读与验证入口

当前 App 默认路线是 iOS 27 + VPN 回环开发者服务截图/触控（免 ESP32）；可在设置选择 ESP32 NCM 模式，复用系统配对身份与 CoreDevice 后端。ScreenCaptureKit + PA3 USB Device NCM/HID 和 TLS 实现保留，旧链路暂未提供切换开关。先读 `README.md` 和本次改动涉及的源码；项目待办重评/证据在 `docs/PROJECT-TODOS.md`。

默认检索范围：`ios-app/Tapito`、`ios-app/TapitoTests`、`ios-app/TapitoUITests`、`firmware-device/main`、`tests/usb_device`。不要默认递归读取 `.build/`、`archives/`、`ios-app/Vendor/` 或旧 Host `firmware/`、`tests/usb_host_sim/`；当问题涉及相应实现、上游兼容或历史证据时再按需查看。许可证与来源清单保留。

默认验证：

- PA3 协议/停止释放：`CC=clang bash tools/test_usb_device.sh`（仅回环网络）。
- App 改动：`bash ios-app/scripts/test_core.sh <隔离模拟器 UDID>`；加 `RUN_UI_TESTS=1` 跑现行 UI 用例。
- 最终无签名 iPhoneOS build：参见 `ios-app/README.md`。
- 核心协议、单次授权、会话隔离、未知结果、不重放、checkpoint 迁移和停止释放测试始终保留在默认 target。不能为缩短验证删除这些覆盖。

归档入口见 `archives/README.md`。非核心 PiP 状态展示和 Siri UI 测试可通过 `INCLUDE_ARCHIVED_TESTS=1 python3 ios-app/scripts/generate_xcode_project.py` 临时加入；结束后不带该变量重新生成默认工程。旧控制调试 UI 用例是历史证据，不代表当前导航验收。固件 Host 测试的原目录和脚本继续保留，按涉及范围显式运行。
