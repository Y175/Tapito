# TapPilot 开发记录

更新：2026-10-15。工程目录 `/Users/y175/code/TapPilot`。

## 全新应用命名

用户明确指定名称 TapPilot，并要求不兼容旧版、不迁移历史数据。源码类型、Swift Package、工程、scheme、主 target、测试 target、后端库和运行时名称统一更名。

| 项目 | 标识 / 名称 |
| --- | --- |
| 主 App | `TapPilot` / `com.y175.tappilot` |
| URL scheme | `tappilot` |
| VPN 扩展 | `TapPilotLoopbackTunnel` / `com.y175.tappilot.LoopbackTunnel` |
| 系统 VPN 配置 | `TapPilot 本机连接` |
| 活动扩展 | `TapPilotLiveActivity` / `com.y175.tappilot.LiveActivity` |
| 操作按钮控制 | `TapPilot 语音任务` |
| 户外快捷指令 | `TapPilot 户外初始化` |
| 独立模块 | `TapPilotConnectionKit`、`TapPilotVoiceKit`、`TapPilotNCM` |
| 模型工具命名空间 | `tappilot` |

新 App 具有独立沙箱、Keychain 服务标识、配置键和系统授权。首次使用需配置模型、在新 App 内配对、授权 VPN / 语音 / 定位、添加新快捷指令并绑定新控制。旧 App 与用户已导入的旧快捷指令不被删除或修改。

户外快捷指令必须使用新 Bundle ID 重新生成与签名；初始化编号、离线回执、结果的三个文本变量绑定保持不变。登录回调页面的 Content-Length 改为根据 UTF-8 正文实际字节数生成。

## 构建与验证

- macOS 模块测试：连接 15 项、语音 18 项全部通过；Rust 后端 52 项及协议依赖 176 项全部通过。
- Apple 本机快捷指令解析器验证初始化编号、离线回执、最终结果三个文本变量绑定均可无损往返；新快捷指令签名成功。
- 374 个源码/配置文件扫描通过；运行代码与配置无旧品牌标识，所有本地化目录与 plist 可解析。许可证和第三方署名未变更。
- iPhoneOS `build-for-testing` 成功，App、实时活动、VPN 扩展和测试 target 均编译通过；没有启动 iOS 测试运行。
- 最终扁平「鼠标点击黑洞」图标已接入，1024 × 1024 不透明 PNG。更换最终图标后的 iPhoneOS build 成功；[图标设计与完整提示词](TapPilot-ICON.md)。
- 产物核对：主 App 与扩展 Bundle ID / 显示名、中文与英文 App 名称、URL scheme、Intent 元数据均为新标识；包内签名快捷指令与源码资源逐字节一致。
- 未签名 App：`.build/TapPilotDevice/Build/Products/Debug-iphoneos/TapPilot.app`。本轮未安装新 App、未启动模拟器或执行真实手机任务。

证据保存在 `.build/tappilot-rename/`：`connection-tests.log`、`voice-tests.log`、`rust-tests.log`、`final-iphoneos-build.log`、`FinalBuild.xcresult`、`icon-final-build.log`。开始修改前的差异、文件副本和路径变更清单也在该目录，不覆盖先前工作。

```sh
python3 ios-app/scripts/generate_xcode_project.py
swift test --package-path ios-app/TapPilotConnectionKit --scratch-path .build/tappilot-validation/connection
swift test --package-path ios-app/TapPilotVoiceKit --scratch-path .build/tappilot-validation/voice
bash tools/test_ncm_rust.sh
python3 ios-app/scripts/build_outdoor_shortcut.py --team <Apple-Team-ID>
xcodebuild -project ios-app/TapPilot.xcodeproj -scheme TapPilot \
  -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath .build/TapPilotDevice CODE_SIGNING_ALLOWED=NO build-for-testing
```

## 历史证据

重命名前的真实日志、测试数字和安装记录完整保留在 [历史开发记录](../archives/history/ORVA-DEVELOPMENT-2026-10-15.md)，其中旧路径和名称表示当时的版本，不是当前 TapPilot 的验证结果。上游来源、许可证和 Git 历史保持原貌。
