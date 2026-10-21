# 可恢复归档

- `history/docs/`：旧 Host 方案、阶段集成、导入、构建及 USB 早期文档；原日期与验证范围保留，不能当作当前状态。
- `history/ios-app/docs/`：旧 UI、Siri、Live Activities、后台和构建阶段说明；截图已移除。
- `history/README.md`、`history/ios-app/README.md`：精简前完整入口，方便追溯。
- `tests/TapitoTests/StatusTests.swift`：非核心 PiP 展示测试。
- `tests/TapitoUITests/SiriEntryUITests.swift`：本次未修改的 Siri UI 流程测试。
- `tests/obsolete/ConversationUITests.swift`：已被设备面板替换的旧导航、调试及视觉验收证据，不直接加入当前 target。

可恢复测试：在仓库根目录运行 `INCLUDE_ARCHIVED_TESTS=1 python3 ios-app/scripts/generate_xcode_project.py`，再用默认测试脚本；完成后不带该变量重新生成工程。归档不删除用户会话、截图或配置，也不抹掉固件历史。

2026-10-16 已移除 ESP32/旧 Host 固件、专用测试和工具链；归档文档中的历史路径不再代表现存文件。当前默认测试仍包括输入授权、会话失效、不重放、停止释放、审批记录、Live Activity 导航隔离和 Siri command 权限回归。
