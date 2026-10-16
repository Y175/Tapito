# ORVA 开发记录

更新：2026-10-14。工程目录 `/Users/y175/code/ORVA`，本地分支 `feature/ORVA连续语音`。

## 来源与边界

从 Actell 上游提交 `e701786d1686823f9ab60524e689e387b7c3b904` 创建独立 Git checkout，保留完整历史、GPL-3.0 和第三方来源说明。上游仅配置为 `upstream`；未创建远端、提交或推送。展示名 ORVA，开发 Bundle ID `com.y175.orva`，扩展 `com.y175.orva.LiveActivity`，独立 `orva://` 链接。内部目录、类型、工程和 scheme 保留 PhoneAgent，便于持续跟踪上游。

用户已授权新建工程和开发，并于 2026-10-14 明确要求“直接装到真机”，授权签名、安装和启动验证，目标为 175phone（iPhone 18 Pro）；不包括执行真实手机任务。图标还未选定，原资产仅作为开发占位，不代表最终 ORVA 品牌图标。签名团队留空，不沿用上游作者的团队。

## 已确定的交互

新增独立入口：左侧操作按钮 →「开始语音任务」→ 后台收音与实时活动 → 灵动岛「结束语音」。这个入口不使用快捷指令“听写文本”，也不调用原“执行任务”入口；首次权限准备仍在 App 中完成。以下原有文字入口保持可用。

1. 长按 iPhone 操作按钮 → 快捷指令“听写文本” → ORVA“执行任务”的“任务”参数；“连续语音对话”开关默认开启。
2. 首次语音启动需要 App 前台、解锁、麦克风与语音识别权限。按系统要求进行前台交接，不能保证绕过 Siri 的系统确认提示。
3. 一次主动激活后保留同一会话，回答播报后继续聆听。首版使用中文离线识别和系统中文播报，未接入 OpenAI Realtime 或云端语音转录。
4. “允许语音打断”默认关闭并持久保存；执行及播报期间不提交、不排队新语音，任务完成后继续聆听，也可点击“结束”。开启后仅在完整语句为明确任务口令（如“暂停任务”）或以“ORVA”开头时打断；普通聊天和部分识别结果不打断。新指令仍须等待原运行的传输与 agent 清理完毕；已发出动作不会自动撤销，结果未知的动作不得自动重发。
5. App 在等待输入时提供暂停、恢复和结束；忙碌时始终可点击“结束”，打开打断开关后另有“打断”按钮。语音“结束对话”“停止对话”“退出语音”在等待输入或允许语音打断时退出；关闭打断后的忙碌期间也忽略这些口令。锁屏、音频中断、耳机断开、识别错误或采集停止都会终止语音并展示错误，不会自行重新收音。
6. 灵动岛跨多轮保持同一语音活动，展示准备、聆听、思考、当前操作、停止中、播报、暂停和错误。操作计数是本轮已处理调用数，不等于已成功执行步骤；不展示原话、截图、参数或接口地址。点击仍定位实际运行轮次。

## 当前实现

- `ios-app/ORVAVoiceKit`：语音状态机、音频接口、Speech/AVAudioEngine 适配器及无设备依赖测试。
- `ios-app/PhoneAgent/Voice`：复用现有模型和设备执行器，提供控制条与灵动岛映射。
- `AgentViewModel` / `ConversationStore`：语音独占提交入口，保留同一聊天上下文和公共操作状态；语音模式下每轮结束不自动拉回 App。
- `AgentIntents`：接收快捷指令文字、连续语音开关、查询语音状态、结束语音；关闭连续语音时保留单任务入口。
- `StatusPiPController`：语音会话占用音频时停止旧播放模式，等待其释放，避免录音与播放会话互相抢占。真实麦克风帧才提供音频活动凭据，采集停止会撤销。
- 工程生成器：加入语音包、权限描述和独立标识。保留原相册权限及全部原测试目标；重新生成造成工程文件格式变化。

## OpenAI 配置

入口：设置 → 供应商 → OpenAI 或自定义供应商。填写 HTTPS Base URL（局域网代理可填私有 IPv4 HTTP）、API Key、模型，显式选择 OpenAI Chat Completions 或 OpenAI Responses。官方基础地址为 `https://api.openai.com/v1`，不要填入具体 `/chat/completions` 或 `/responses` 路径。兼容服务按自己的完整基础地址填写，代码不会猜测或补 `/v1`。

HTTP 仅允许标准四段式私有 IPv4：`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`。公网 IP/域名、DNS 别名、IPv6 和手机回环地址不能用 HTTP；它们仍需 HTTPS。统一地址策略在配置、模型发现和两种推理协议中执行，现有禁止重定向的传输策略保留。Info.plist 仅加入 `NSAllowsLocalNetworking`，没有启用全局 `NSAllowsArbitraryLoads`；本地网络用途说明覆盖模型代理，编辑 HTTP 地址时显示明文传输提示。首次访问局域网需允许系统权限。参见 [Apple 本地网络 ATS 说明](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)。

“设置 → 供应商 → 默认供应商”可固定新会话使用的供应商及其配置的默认模型；快捷指令和连续语音的新会话使用相同选择。单个已有会话临时切换供应商或模型不会更改全局默认。会话输入区始终显示“供应商 · 模型”，无需打开键盘才可选择。

语音任务使用所选供应商和模型。手机控制还要求模型支持图片输入及工具调用；能列出模型不代表这些能力已经可用。用户后续真机截图已显示模型回复与工具调用记录，并反馈执行时被无关对话打断；这不能代替完整任务与语音功能验收。原始录音由本地语音适配器处理，不落盘；转写、对话和任务截图仍按现有模型链路发送及存储。

### 本地代理实测（2026-10-14）

按用户要求，在 Mac 使用用户提供的凭据测试 `http://127.0.0.1:8317/v1`。凭据不写入工程或报告。模型列表返回 HTTP 200；`gpt-6.1-sol` 的 Chat Completions 与 Responses 非流式请求分别约 2.89 秒、3.18 秒返回预期文字 `ORVA_PROXY_OK`；Responses 流式请求约 2.81 秒返回 `ORVA_STREAM_OK`，收到 `response.completed`，没有错误事件。这里只验证文本推理及流协议，未验证图片、工具调用或任务执行。

用户随后明确授权开放局域网监听并增加 ORVA 的局域网 HTTP 支持。已通过 EasyCLIProxyAPI 设置将监听地址从 `127.0.0.1` 改为 `0.0.0.0` 并重启代理；GUI 配置和实际内核配置已保存，API Key 鉴权保留，远程管理仍关闭。Mac 当前局域网 IP 为 `10.10.15.46`，基础地址为 `http://10.10.15.46:8317/v1`。通过该地址查询模型：带 Key 为 200 / 22 个模型，无 Key 为 401；Responses 流式推理约 2.74 秒返回 `ORVA_LAN_OK` 并完整结束。这些请求由 Mac 发出，尚不能单凭这些结果断言 iPhone 的 Wi-Fi 路由和本地网络权限已经验证。

真机配置：供应商选 OpenAI-compatible；地址 `http://10.10.15.46:8317/v1`；填入已有 Key；API 选 OpenAI Responses；模型可选已实测的 `gpt-6.1-sol`。手机和 Mac 需在可互通的局域网中，Mac 换网或 DHCP 地址变化后应更新地址。Key 未写入源码、测试或报告。

## 验证记录

- 局域网 HTTP：ProviderKit 新增 5 项边界与协议测试全部通过，覆盖私有网段边界、公网/别名/回环/非标准 IP 拒绝、凭据/查询/片段/端口拒绝，以及 Chat Completions / Responses 请求编码与禁止绕过。
- 175phone 真机执行 `ModelDiscoveryTests` 和 `ProviderTransportTests` 共 25 项，全部通过，未跳过；包含新加入的 HTTP 模型发现与推理一致性测试。使用合成凭据和桩请求，不产生实际手机操控。首次增量构建读取到旧 ProviderCore 模块而失败，clean 后完整重建通过。
- HTTP 改动的完整无签名、签名构建均通过，签名深度校验通过；已将更新后的 ORVA 安装到 175phone 并正常启动，截图确认会话首页和连续语音入口正常显示。安装包中的 ATS 设置和中文本地网络用途说明已核验。
- 核心语音状态机：当前 16 项 XCTest 全部通过，覆盖连续轮次、打断等待清理、暂停恢复、晚到回调、权限失败、许可弹窗期间结束、播报打断、未知/受阻结果及启动失败传播；新增关闭打断不排队、跨忙碌边界的识别结果丢弃、无关对话不打断、关闭开关清空候选指令和手动打断门控。
- PA3 协议/停止释放：C 协议测试及 25 项 TCP 测试通过。使用已安装 Command Line Tools 执行，不连接 iPhone / ESP32。
- 修改及新增的 24 个 Swift 源文件语法解析通过；语音核心、Apple 音频适配器及 Live Activity 在 iPhoneOS SDK 下的 Swift 5 严格并发类型检查通过。
- 工程 plist 校验通过；生成器语义对比没有移除原 source/test 对象；保留原相册权限描述。3 项语音 App 集成测试已在 175phone 执行通过，覆盖停止回执、提交预留和灵动岛路由。
- 本机现为 Xcode 27.0（27A266a）、iPhoneOS 27.0 SDK、Rust/Cargo 1.99.0，Xcode 首次初始化完成。完整无签名构建和 Apple Development 签名构建均通过；用户已自行登录 Apple 账号并处理新版开发者协议，自动签名描述文件包含目标手机。
- ORVA 0.1.0（`com.y175.orva`）已安装到 175phone（iPhone 18 Pro / iOS 27.0.1）。`codesign --verify --deep --strict` 通过，`devicectl` 安装和启动均返回成功，真机截图确认设置页正常显示。
- **未完成：完整 App 单元/集成/模拟器测试，以及连续收音、播报防回声、快捷指令、后台行为、灵动岛和真实手机任务的功能验收。** 本机缺少 iOS 27 模拟器运行时；用户选择先安装到真机。安装和启动通过不等于这些功能已验证。

本地证据（已 gitignore）：`.build/orva-voice-tests.log`、`.build/orva-protocol-tests.log`、`.build/orva-swift-parse.log`、`.build/orva-ios-check/`、`.build/orva-device-build.log`、`.build/orva-signed-device-build.log`、`.build/orva-install.json`、`.build/orva-launch.json`、`.build/orva-first-launch.png`。

HTTP 改动证据：`.build/orva-provider-tests.log`、`.build/orva-http-device-test.log`、`.build/ORVA-LAN-HTTP-Tests2.xcresult`、`.build/orva-http-unsigned-build.log`、`.build/orva-http-signed-build.log`、`.build/orva-http-install.json`、`.build/orva-http-launch.json`、`.build/orva-http-launch.png`。真机测试报告确认 25 passed / 0 failed / 0 skipped。

### 无关对话误打断与默认供应商（2026-10-14）

用户反馈执行任务时周围的无关对话进入会话并打断任务。原实现收到任何非空部分识别结果便取消运行。现在部分结果只参与语句状态跟踪，不直接停止任务；完整语句须经过打断开关及明确口令判断。关闭打断后直接丢弃执行/播报期间的语音，即使该语句的最终识别回调晚于任务结束，也不会补交为新任务。关闭开关会清除已排队的修改指令，绝不恢复或重放已停止的任务。显式停止原因区分语音口令、手动打断、暂停、结束与音频故障；诊断仅记录固定状态和原因，不记录原话或录音。

供应商存储新增可选 `defaultProviderID`，已有配置可读取。明确默认使用该供应商配置的默认模型，最近会话的临时选择不会覆盖它；已有会话保留原供应商和模型。配置里的默认 ID 无对应供应商时显示读取错误并保留原数据。移除当前默认会清除该选择，确认框明确说明；恢复供应商不会重新设为默认。未指定默认时保留原有最近选择规则。没有代用户指定某一个实际供应商。

验证：语音核心 **16 passed / 0 failed**；175phone 运行供应商选择、3 项语音集成和快捷指令默认初始化相关测试共 **24 passed / 0 failed / 0 skipped**，无运行时警告。测试覆盖默认持久化、临时选择不覆盖默认、默认模型更新、新旧会话隔离、无效 ID、移除与恢复、快捷指令无需先打开会话即可使用默认。使用合成配置与桩执行器，未执行真实手机任务。

最终无签名与签名构建、签名深度校验通过，已更新安装到 175phone 并通过 `orva://home` 启动。首页真机截图确认“允许语音打断”默认关闭、说明文字完整显示。默认选择的存储与调用路径已有真机测试；真实外放/耳机环境的收音和防误识别仍需用户实测，未以合成语音事件测试代替声学验收。

证据：`.build/orva-voice-interruption-tests.log`、`.build/orva-voice-default-device-tests.log`、`.build/ORVA-Voice-Defaults-Tests.xcresult`、`.build/orva-voice-default-unsigned-build.log`、`.build/orva-voice-default-signed-build.log`、`.build/orva-voice-default-install.json`、`.build/orva-voice-default-launch.json`、`.build/orva-voice-default-launch.png`。

## 后续验证入口

### 操作按钮后台录音与灵动岛结束（2026-10-14）

新增 `StartVoiceTaskIntent: AudioRecordingIntent, LiveActivityIntent`，无文字参数，`supportedModes = .background`，不请求前台交接，要求设备本地认证；权限未授予时明确提示先在 ORVA 中授权。录音权限检查、会话准备、实时活动创建及确认、麦克风启动按顺序执行；实时活动不可用时不启动录音。持续检查活动是否仍存在，关闭活动会停止录音与后续任务。保留语音独占、默认供应商、默认关闭打断和未知结果不重放规则。

灵动岛展开区域和锁屏实时活动新增「结束语音」按钮，通过共享 `EndVoiceSessionIntent` 在主 App 进程停止指定语音会话；旧活动的按钮不能停止后来的会话。控件使用语音会话身份，而非某个模型轮次或常驻活动的原始身份。代码通过工程生成器纳入 App 与扩展两个 target，扩展不创建另一套语音运行时。录音期间的锁定处理由语音控制器直接订阅，不依赖 SwiftUI 页面出现。冷启动后的后台任务资格只接受该语音会话实际麦克风帧的凭据，不把 Intent 调用或灵动岛可见视为执行资格。

操作：首次在 App 中完成语音权限并结束会话；在「快捷指令」创建只包含 ORVA「开始语音任务」的快捷指令，再在「设置 → 操作按钮 → 快捷指令」选择它。保持解锁，返回主屏幕或其他 App 后长按操作按钮，看到灵动岛「聆听」再说任务。结束时长按灵动岛展开，点「结束语音」；「查看会话」仍是进入 App 的独立链接。长按按键的绑定属于 iOS 用户设置，App 不会自行更改它。

这项实现区分核心/集成测试与真实系统入口验收：直接调用 `perform()` 的测试不能证明系统授予了后台麦克风资格。175phone 主屏幕上的后台启动、橙色录音指示与灵动岛结束已由用户实际验证；进程被终止后的冷启动尚未单独验证，不能由后台状态推断。按用户要求不使用模拟器。

验证：语音核心 **21 passed / 0 failed**，包括准备期间锁定/失败必须返回错误，不能误报启动成功；PA3 C 协议检查和 **25 项 TCP 测试通过**。175phone 上执行语音集成、实时活动及快捷指令相关 **48 项测试全部通过，无跳过**，包括实时活动失败不收音、启动期间结束、旧活动身份不能停止新会话、冷启动语音帧资格与文字入口隔离。测试宿主通过临时 `.xctestrun` 参数 `-backgroundResidentEnabled NO` 关闭实际后台待命，避免用户保存的媒体待命状态污染“没有播放”的负向断言；未改写用户持久设置。

完整 App 单元测试首次执行 **433 项，424 passed / 9 failed**。其中一项本轮错误文案变化已恢复，一项旧 `phoneagent:` URL 断言已改为当前 `orva:`，一项媒体宿主状态干扰通过上述隔离复核；余下 **6 项附件存储/发送/历史测试报「附件目录包含非法路径引用」**，相关存储实现未在本轮修改，仍需单独定位，不能将本轮记为全量测试通过。源码及测试 target 成员未移除；工程生成器仅新增共享 Intent 的两个 target 引用及 App 编译标记。App 与扩展的产物 metadata 确认两个 Intent 的后台模式、主进程目标及录音协议均已提取。

证据：`.build/orva-recording-intent-core-tests.log`、`.build/orva-recording-intent-protocol-tests.log`、`.build/ORVA-Recording-Intent-Tests.xcresult`、`.build/ORVA-Recording-Intent-Isolated2-Tests.xcresult`、`.build/orva-recording-intent-final-unsigned-build.log`、`.build/orva-recording-intent-final-signed-build.log`。

首版无签名和开发签名 iPhoneOS 构建均成功，`codesign --verify --deep --strict` 通过。已通过局域网覆盖安装到 175phone，并通过 `orva://home` 正常启动；产物中文资源已确认「开始语音任务」名称。安装与启动证据：`.build/orva-recording-intent-install.json`、`.build/orva-recording-intent-launch.json`。

用户截图确认手机保持主屏幕，灵动岛显示「正在聆听」及橙色麦克风指示；用户点击「结束语音」后确认已结束且未打开 App。设备日志 `.build/orva-recording-intent-user-verified.log` 在北京时间 15:16–15:17 记录三组 `voice.intentStart foreground=false` → `voice.intentStarted foreground=false` → `voice.phase value=ended` → `voice.intentEnd matched=true`，与用户反馈一致。该验证只涉及开始/结束录音，没有执行真实手机任务。

截图同时暴露展开灵动岛的第二个按钮被裁切。已将「结束语音」与「查看会话」调整为同一行、各自至少 44 pt 高度，锁屏卡片保持一致布局；按钮仍分别调用结束 Intent 和会话链接。该调整与准备失败传播修正已重新通过 21 项核心测试、无签名/开发签名 iPhoneOS 构建及签名校验，并无线安装到 175phone；更新后的实际按钮排布待用户再次展开核对，未使用模拟器或自动执行任务。证据：`.build/orva-recording-intent-layout-unsigned-build.log`、`.build/orva-recording-intent-layout-signed-build.log`、`.build/orva-recording-intent-layout-install.json`。

#### 操作按钮自动展开与启动延迟

用户随后说明，期望长按左侧操作按钮后自动展开控制区，并反馈从按键到「聆听」约 2–3 秒。截图是有效活动的紧凑态，不是录音未开始。设备日志 `.build/orva-recording-intent-latency-before.log` 显示三次准备态到聆听内容时间约 0.24–0.28 秒，但旧日志从运行时初始化之后才开始记录，无法说明完整按键延迟或冷启动成本。

调整：语音准备阶段仍建立活动以满足录音前置条件，首次展开提醒改为聆听就绪时发送；准备和聆听不再等待普通进度的 300 ms 合并窗口；已授予的麦克风/识别权限直接检查，不重复发起授权请求。保留失败可见、录音前必须有有效活动、结束会话身份校验及普通工具进度合并。新增 `voice.intentEntry`、`voice.runtimeReady elapsedMs`、`voice.intentReady elapsedMs`，用于区分进入 Intent 后的初始化/录音耗时；这些计时仍不包含按键识别及系统调度之前的时间。

平台行为：提醒更新可以请求短暂展开，系统之后会回到紧凑态，不能把该请求等同于持久展开的确认；长按顶部活动可手动展开。依据：[Apple 对提醒更新及收起行为的说明](https://developer.apple.com/videos/play/wwdc2024/10098/)、[灵动岛操作说明](https://support.apple.com/guide/iphone/view-live-activities-in-the-dynamic-island-iph28f50d10d/ios)。当前没有通过额外延迟或重复提醒来强行维持展开。

本轮相关真机测试 **49 passed / 0 failed**，涵盖独立活动与复用待命活动均在聆听时仅请求一次展开，证据 `.build/ORVA-Voice-Startup-Tests.xcresult` 和 `.build/orva-voice-startup-device-tests.log`。无签名/开发签名 iPhoneOS 构建及深度签名校验通过，已无线安装到 175phone；证据 `.build/orva-voice-startup-unsigned-build.log`、`.build/orva-voice-startup-signed-build.log`、`.build/orva-voice-startup-install.json`。真实展开效果与总按键延迟须由更新后的用户操作核对，不能由桩测试推断。

用户提供 15:32 的录屏，并明确说明末尾展开是手动长按。录屏验证两个按钮完整并排显示、结束有效，**未验证自动展开成功**。新计时记录显示两次 Intent 内部启动分别 394 ms / 651 ms，运行时准备分别 54 ms / 1 ms；这不包含按键识别、系统调度和屏幕最终显示延迟。

#### 直接控制绑定与临时展开面板

按用户截图中的「控制」入口新增 `ORVAVoiceTaskControl: ControlWidget`，固定 kind `com.y175.orva.voice-task-control`，显示「ORVA 语音任务」。用户可在「设置 → 操作按钮 → 控制 → 选取控制」直接选它，跳过快捷指令执行环节。`StartVoiceTaskIntent` 移到 Shared，以便主 App 与控件扩展共享元数据，后台录音仍仅在主 App 进程执行，扩展误执行会明确返回错误。绑定属于用户的 iOS 设置，不由 App 改写。

原有标准活动提醒在录屏中未自动展开。新增独立的 `.transient` 活动负责启动时的展开控制区，标准活动仍在收音前创建且持续保留，麦克风健康检查只依赖标准活动。临时控制区收起/结束不会撤销持续录音资格；结束语音会关闭两者，旧会话按钮不能结束新会话。临时面板创建失败会返回启动错误，不悄悄退回只显示紧凑态的路径。不再同时发送标准活动的启动提醒来争夺展开位置。平台依据：[ActivityStyle 参数说明](https://developer.apple.com/documentation/activitykit/activity/request(attributes:content:pushType:style:))。

本轮相关真机测试 **51 passed / 0 failed**，增加临时控件关闭与收音活动隔离、同会话结束释放、创建失败返回及进度同步检查。无签名/开发签名 iPhoneOS 构建及深度签名校验通过，已无线安装到 175phone。证据 `.build/ORVA-Direct-Control-Tests.xcresult`、`.build/orva-direct-control-device-tests.log`、`.build/orva-direct-control-final-unsigned-build.log`、`.build/orva-direct-control-final-signed-build.log`、`.build/orva-direct-control-install.json`。控件列表可见、直接按键启动、临时控制区实际展开及总延迟均待用户在新入口复测，不能由编译或桩测试推断。

#### 真机复测失败与空白活动清理（后续修正）

用户确认控制可找到，但没有自动展开；结束后长按灵动岛出现空白黑块。设备日志 `.build/orva-direct-control-user.log`：15:45:56 临时活动创建并进入 active，15:46:02 dismissed；15:46:05 语音结束后常驻活动依次更新为 stopped、standby，仍为 active。空白视图来自 standby 的透明内容，不能通过隐藏文字移除系统占位。三个更早的冷启动尝试在标准活动创建后进入 failed，日志没有底层错误码，不能认定具体系统拒绝原因。

修正：删除无任务时预建/复用空白活动的路径，实时活动只由实际运行创建；保留音频常驻设置和执行资格逻辑。停止立即结束并移除活动，重新进入 App 不再重建空白待命，进程启动清理旧版 standby 与遗留语音活动。撤回实测无效且增加启动依赖的双活动方案，录音只依赖一个标准活动，保留直接控制入口和一次聆听提醒。新增启动失败 domain/code 诊断，不记录语音或凭据。自动展开仍未通过真机验收，当前明确使用手动长按岛展开；不宣称系统提醒或编译通过可保证自动展示。

新增回归覆盖：空闲前后台切换不创建活动、停止立即移除、返回 App 不复活待命、再次后台启动使用新句柄、旧会话停止不能结束新会话、只创建一个录音活动。保留现有授权、停止和后台执行覆盖。无签名 iPhoneOS 构建、开发签名测试构建与深度签名校验通过；真机测试首次运行因 175phone 无线离线未启动。用户随后要求先安装；无线连接恢复后已成功安装并启动到 175phone，安装序号 2384，证据 `.build/orva-activity-cleanup-install.json`、`.build/orva-activity-cleanup-launch.json` 与 `.build/orva-activity-cleanup-after-launch.log`。构建证据 `.build/orva-activity-cleanup-unsigned-build.log`、`.build/orva-activity-cleanup-signed-build-tests.log`；失败的测试启动证据 `.build/orva-activity-cleanup-device-tests.log`。本版新增回归测试尚未运行，不能沿用上一版 51 项通过的结果声称本版已通过；结束后空白活动消失仍待用户真机复测。

#### 单活动模拟器验证（2026-10-14，后续证据）

用户已确认清理版的空白灵动岛消失，但自动展开仍未实现；随后明确授权使用 iOS 模拟器，覆盖此前不启动模拟器的限制。本轮仅操作 iPhone 18 Pro / iOS 27.0 模拟器 `586E9308-2238-4AD0-8513-9C4E9A0286E9`，未再次安装到真机。

新增 DEBUG 专用「ORVA 展开验证」Control 和独立 ActivityAttributes。该入口只创建一个 `.transient` 活动，不录音、不调用模型、不执行手机任务；若已有 ORVA 活动则明确拒绝，不终止用户任务。关闭按钮只匹配这次 probe UUID。调试启动参数 `--island-presentation-probe` 提供前台对照按钮，正常启动不显示此界面。

实测结果：

- 主屏幕通过 Device Hub 的 Controls → Action Button 触发后台 `LiveActivityIntent`，自动展开成功；没有触碰灵动岛，没有打开 App。日志 08:33:08Z，activity `70D5AB8F-B560-43FE-8ADF-0A82115F0535`，`foreground=false`。
- 结束活动并停止 App 进程后，再次从模拟操作按钮启动，同样自动展开；08:34:59Z，activity `0622993D-5C25-4C81-A54F-B1F99984282E`。关闭按钮成功结束，没有空白残留。
- 前台直接创建的对照请求成功，但 SpringBoard 明确记录 `can present alert: NO, isHostApplicationForeground: YES, allowAlertsOnHostApp: NO`。因此前台直接调用 `perform()` 不能代替后台入口验收。
- 初次沿用 `CODE_SIGNING_ALLOWED=NO` 导致控件的 Intent 序列化失败；`siriactionsd` 明确记录 insufficient privileges，WidgetKit 抛出 `Can't create CHSIntentReference`。模拟器改为正常 ad-hoc 签名（`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`）后，控制与关闭 Intent 均成功。该现象不能推断成开发签名真机的同一原因。

当前源码下默认 `PhoneAgentTests` 全部 **434 项通过、0 失败、0 跳过**，包括本次空闲无活动、停止立即清理、旧会话隔离及录音活动检查的新增覆盖。证据 `.build/orva-island-simulator-tests.xcresult`、`.build/orva-island-simulator-tests.log`。本轮使用合成模型和隔离存储，没有真实任务执行。

展示证据 `.build/orva-island-probe-sim-signed-action.mp4`、`.build/orva-island-probe-sim-cold-action.mp4`、`.build/orva-island-probe-signed.log`。这证明独立临时活动的后台自动展开可行，尚未证明语音录音与持久活动共存时能自动展开，也未定位旧双活动方案的真机失败根因。正式语音入口仍使用清理版的单个标准活动；不将此诊断结果当作语音功能或真机验收通过。

#### 正式语音入口衔接复测（2026-10-14，当前结论）

本轮通过模拟器的实际 Controls → Action Button 和「ORVA 语音任务」入口继续验证，使用显式开启的 `--orva-simulator-voice` 合成输入。该 DEBUG 模式仅编入模拟器，使用离线模型/桥接与内存会话，不打开麦克风、不发送模型请求、不控制真实手机。`--orva-simulator-voice-off` 或移除模拟器 UserDefaults 的 `orva.simulatorVoiceFixture` 关闭此模式；隔离核心测试始终关闭它。

自动展开尚未解决：标准录音活动创建后再请求临时活动，在 08:51:04Z 返回 ActivityAuthorization domain / code 7；系统日志在本次入口中记录临时 fakeForeground assertion 的 `invalidateOnActivityRequest: true`，首次创建后第二次请求不再拥有活动创建资格。返回 `OpensIntent` 让系统接续执行也在 08:53:50Z 返回相同错误。单个标准活动的立即启动提醒，以及聆听就绪后延迟 3 秒提醒，录屏均仍为紧凑态。返回交互式 snippet 的直接控制入口也未显示结果面板。以上是本机模拟器的实测边界，不能推断所有系统版本或真实音频条件都绝对不支持。

撤回双活动、系统接续、计划启动、延迟提醒和 snippet 实验的正式流程改动，保留清理版的单个标准录音活动、手动长按灵动岛及按会话身份结束。09:06:50Z 与 09:11:48Z 的结束操作确认合成采集停止、活动 dismissed、App 不打开。没有再次安装到 175phone。新增的仅是可重复测试正式控制入口的模拟器合成输入设施。

最终默认核心测试再次 **434 passed / 0 failed / 0 skipped**，证据 `.build/orva-voice-presentation-final-tests.xcresult`。展示证据 `.build/orva-voice-controls-warm.mp4`、`.build/orva-voice-controls-chain.mp4`、`.build/orva-voice-standard-alert.mp4`、`.build/orva-voice-delayed-alert.mp4`、`.build/orva-voice-snippet-control.mp4`；实验源码仅存放 `.build/voice-presentation-experiments/`，不进入正式实现。

接口依据：[AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent)、[实时活动交互](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)、[系统控制与操作按钮](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system)。

### 配对后未连接（2026-10-14）

用户反馈 VPN 回环控制页显示“未连接”。真机截图确认 App 已有配对记录；Mac 侧 CoreDevice 为 paired / connected、开发者模式开启。用户确认手机尚未开启 VPN，因此本机回环传输条件尚未满足。检测到手机已安装 Shadowrocket 2.2.92；外部 VPN 开启、接口地址与回环支持仍需实际核对，不能把 Mac 的 USB 连接或模型代理连通视为 App 控制通道连通。

修复 `PairingSection` 的详情显示条件：已有配对身份时，异步连接失败的 `lastFailure` 也必须显示，避免错误原因被隐藏。VPN 配置页增加“配对仅建立授权”的连接步骤说明。修改后的无签名及签名构建均通过，更新已安装到 175phone；未更改或删除现有配对身份。证据：`.build/orva-connection-device.json`、`.build/orva-connection-screen.png`、`.build/orva-connection-unsigned-build.log`、`.build/orva-connection-signed-build.log`、`.build/orva-connection-install.json`。

### 初始握手断线诊断（2026-10-14）

用户使用 Shadowrocket 直连模式、接口 `198.18.0.1`、对端 `10.7.0.1` 时，页面显示“手机身份认证失败（协议错误）”。安装仅记录固定标签和数字错误码的诊断版本后，真机首次复现为 `step=greeting / code=1 / detail=socket_eof`：读取初始握手回复时连接已关闭，还未执行身份验证。这不能认定配对失效，也没有足够证据确认 Shadowrocket 内部哪项配置导致断线。

后端现在区分初始握手（stage 22）与身份验证（stage 3），EOF、连接重置等明确报告连接提前关闭（cause 15，保留现有截图诊断占用的 8–14）。VPN 页面解释“尚未验证配对身份”，不删除身份、不自动配对或重放。两项新增回归测试覆盖握手 EOF 不发送身份验证/配对、不重连，以及真实认证拒绝不会被误报为传输关闭；原 FFI 测试更新为断线发生的实际阶段。后端 **47 项通过**，无签名与签名 iPhoneOS 构建、签名校验及更新安装均通过。

用户另一个会话处理 LocalDevVPN 安装；本会话随后检测到 `com.y175.localdev.LocalDevVPN` 1.2.1 已安装。持续采集的 ORVA 控制台后续出现 `greeting=ok`、`authentication=ok`，11:32:11 开始出现视频协商和 VideoToolbox 解码器/画面几何日志。因此现有配对身份已成功验证，视频会话已启动；日志没有记录当时启用的 VPN 身份，不能据此将成功归因于某一个 VPN。最新错误提示修正版安装后未再次启动验证，以避免打断另一个会话的 VPN 配置。LocalDevVPN 默认接口/对端为 `10.7.1.1` / `10.7.0.1`，需在实际切换 VPN 后对应保存。没有执行完整模型任务或语音控制验收。

证据：`.build/orva-pairverify-console.log`、`.build/orva-pairverify-rust-tests.log`、`.build/orva-pairverify-unsigned-build.log`、`.build/orva-pairverify-signed-build.log`、`.build/orva-pairverify-install.json`。诊断日志没有配对密钥、身份内容、协议帧或模型请求。

### 会话输入区布局修复与无线安装（2026-10-14）

用户反馈会话页没有聊天输入框。代码中应用外层的连续语音栏与会话页的输入栏分别占用底部安全区，存在布局冲突。现在移除应用外层的底部插入，让首页自己展示语音栏；会话页使用同一个 `safeAreaInset` 按顺序放置语音栏和文字输入区，文字输入区保持在靠近键盘的位置。两页复用同一个语音控制器，未改变任务提交、语音独占或供应商选择逻辑。

修改后的无签名与签名 iPhoneOS 构建、签名深度校验均通过。175phone 的 CoreDevice 连接确认为 `localNetwork`，已无线覆盖安装并通过 `orva://home` 启动。用户要求停止使用模拟器后，已中断 UI 测试、关闭 Simulator 并删除本次创建的隔离设备；该次 UI 测试未完成，不能记为通过。输入框在真机上的显示、键盘弹出及发送交互仍待实际操作确认，安装和启动成功不代替 UI 验收。

证据：`.build/orva-composer-unsigned-build.log`、`.build/orva-composer-signed-build.log`、`.build/orva-composer-install.json`、`.build/orva-composer-launch.json`。

开发工具与签名阻塞已解除。本机已安装 iOS 27 模拟器运行时；用户先要求停止使用，随后为灵动岛问题明确重新授权模拟器测试，最新结果见上方「单活动模拟器验证」。

```sh
python3 ios-app/scripts/generate_xcode_project.py
swift test --package-path ios-app/ORVAVoiceKit --scratch-path .build/orva-voice
CC=clang bash tools/test_usb_device.sh
# App 测试需安装与 SDK 匹配的模拟器运行时
bash ios-app/scripts/test_core.sh <隔离模拟器UDID>
xcodebuild -project ios-app/PhoneAgent.xcodeproj -scheme PhoneAgent \
  -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath .build/ORVADevice CODE_SIGNING_ALLOWED=NO build
```

真机功能验收仍须验证：快捷指令冷启动及权限拒绝；中文停顿分句；外放/耳机播报不会把自身声音识别为新任务；执行时打断且不重放已送达动作；不同 App 间切换后持续收音；锁屏、来电和音频路由变化停止；灵动岛状态、点击定位与过期提示。语音与系统后台资格不能保证无限持续，需按真机证据判断。

参考接口：[App Intent 前台交接](https://developer.apple.com/documentation/appintents/appintent/continueinforeground(_:alwaysconfirm:))、[Speech 实时音频请求](https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest)、[AVAudioEngine 语音处理](https://developer.apple.com/videos/play/wwdc2019/510/)。

### 内置技能优化与本地 OCR 实现（2026-10-14）

用户授权实施内置技能与截图评估方案，随后明确要求构建后不安装、不要再发起模拟器测试。当前实现：`ios-operation` 1.1.0，核心从 5298 字符缩为 1871 字符，保持原有 2000 字符分页上限；详细输入/搜索、观察/错误处理移到两份 references 文档。技能包加载覆盖全部参考资源、计算整包 revision，失败显示 warning，不再静默丢失内置技能。没有改变已导入用户技能的内容。

新增 `VisionScreenTextRecognizer`、`observe_screen`、`tap_text`；识别中英文并将 Vision 左下角归一化边界框转换为与截图/点击一致的左上角像素空间。模型收到文字候选、confidence、frame_id、宽高、方向、分页和识别耗时，不收到 OCR 图片。OCR 按计算阶段显式选择支持的 CPU 设备，缺失所需语言/设备或识别错误均明确失败，避免自动切换模型掩盖错误。局部输入、停止、新观察使旧 OCR 候选失效；点击仍经过现有任务授权与桥接会话检查。`screenshot(frame_id)` 为明确的同帧视觉升级，不再次截图；同名/低置信度候选拒绝直接点击，OCR 不代表控件树、焦点或可点击性。未引入 Jev、WDA 或新的供应商切换。

已聚焦字段直接使用现有整段剪贴板输入，不点键盘字母；输入不自动提交、不保证替换、不重发未知结果。系统提示词、工具描述、聊天工具名称和灵动岛操作图标同步。

第一轮默认测试 **443 passed / 1 failed / 0 skipped**，证据 `.build/orva-skills-ocr-tests.xcresult`。真实 Vision 中英文识别、横竖屏像素、空结果与执行错误、同帧视觉复用、旧帧/重名/低置信度拒绝、停止隔离与分页检查通过。端到端合成 provider 测试未处理 SDK 的 `[Tool: observe_screen] OK` 前缀，已按实际格式修正；根据用户最新要求没有复跑，不能记为全部测试通过。该测试已在 iPhoneOS build-for-testing 中编译验证，没有启动测试或安装 App。CPU 设备选择的最终改动同样仅完成构建检查，尚未运行验证。

最终构建证据 `.build/orva-skills-ocr-final-iphoneos-build.log`，产品 `.build/ORVAOCROnlyBuild/Build/Products/Debug-iphoneos/PhoneAgent.app`。未签名，未安装到 175phone；模拟器关闭。当前没有真实 App 搜索任务的端到端耗时/成功率基准，不承诺具体提速比例。

用户随后明确要求安装到真机。完成签名构建与 `codesign --verify --deep --strict` 校验，检查包内技能为 1.1.0 且包含两份 references。通过 CoreDevice 的 `localNetwork` 连接无线覆盖安装到唯一授权设备 175phone（UDID `00008160-00060D3926A0000A`），`com.y175.orva` 安装成功，启动后主进程 PID 2660 存在。没有重新运行模拟器测试，也没有执行真实手机任务。安装与启动成功不代表真机 OCR 或任务效果验收通过；上述测试及 CPU 设备运行验证限制仍保留。

签名产品 `.build/ORVADevice/Build/Products/Debug-iphoneos/PhoneAgent.app`；证据 `.build/orva-skills-ocr-signed-build.log`、`.build/orva-skills-ocr-install.json`、`.build/orva-skills-ocr-installed-app.json`、`.build/orva-skills-ocr-launch.json`、`.build/orva-skills-ocr-processes.json`。

### OCR 执行约束与视频启动诊断（2026-10-14）

内置技能 1.1.1（核心 1990 字符）增加当前帧视觉证据检查：普通 tap 不能用只做过 OCR 的坐标绕过 tap_text。文字候选明确返回 text_target；screenshot 默认复用有效 OCR 帧，同一帧再次查看不重新上传，新画面需 refresh_reason。导航后需核对预期页面。仅明确未发输入的观察要求错误保留原帧，传输/未知结果仍使参照失效。视频准备失败在本任务内阻止重复屏幕/触控请求，不自动重配或重连。

18:18 的签名 build-for-testing、深度签名校验通过，已无线安装并启动 175phone；包内确认技能 1.1.1 及 Rust ORVA_VIDEO_NEGOTIATION 诊断标签。Rust 定向测试 3 项通过；Swift 新回归用例只编译，没有启动模拟器测试。随后 knownUnsent 回执小修正也完成签名构建，但用户打断后未再次覆盖安装，不能把构建当已安装。

22:03 用户反馈后，只读获取最近三次任务：21:57、21:59、22:00 均查询/启动 App 成功，首屏请求在视频启动协商 stage15/cause1 失败，OCR 未开始；同任务后续屏幕调用被拦截。当前 Rust 详细来源仅写控制台，未进入可导出的沙箱日志，这是诊断缺口，不能声称具体根因已定位。用户要求停用子 agent 后已中断，后续由主代理核对。证据 `.build/orva-video-latest-conversations.json`、`.build/orva-video-latest-background.log`。

常用 App 自学习已按用户选择记录为后续方案，尚未实现：学习按 App/版本/任务/画面布局绑定，重复成功必须有结果证据，历史坐标仅作线索，执行前核对当前锚点并重新获取候选；独立版本记录可停用/回滚，不更新安全规则或重放历史授权。

### 视频启动诊断持久化与 USB 安装（2026-10-14）

Rust 将固定分类、code/subcode/elapsedMs 附加到对应视频启动请求回执，Session 逐次清除旧诊断，成功与失败均携带自身 metadata；C ABI 布局和原 stage/cause 不变。Swift 校验固定字段与分类后，原子写入独立 Documents/ncm-protocol-events.log（最多 1000 行、512 KiB）。日志记录认证连接的诊断标识、request ID、stage/cause；不保存远端正文、画面、请求参数或配对密钥。写入失败显式报错，保留原始数值故障信息。

Rust 定向测试 3 项通过；Mac 直接编译真实 NativeProtocolDiagnostics 源码的落盘检查通过，验证成功/失败/超时、读回、非法字段与换行拒绝、存储故障可见。没有模拟器测试或真实任务执行。最终签名构建、深度签名验证通过，包内确认持久化文件名与原生诊断标签；175phone transportType=wired，经 USB 安装并启动成功。之前只构建的 knownUnsent 小修正本次也已安装。

证据 .build/orva-persistent-diag-rust-tests.log、.build/orva-persistent-diag-final-signed-build.log、.build/orva-persistent-diag-install.json、.build/orva-persistent-diag-launch.json。具体视频启动根因仍需用户在该版本复现后读取新日志，不把诊断修复称为协议故障已解决。

### 连续语音音频配置修正与设备错误链（2026-10-14）

两组真机记录呈现普通任务取帧成功、连续语音任务在视频协商阶段失败；尚未证明系统拒绝的具体原因。本轮修复将 AppleVoiceAudio 从 playAndRecord/voiceChat/Voice Processing 改为 playAndRecord/default/mixWithOthers，并显式关闭 Voice Processing、检查实际模式。保留实际麦克风采集与后台执行凭据，仍按原策略丢弃关闭打断时的忙碌语音，不重放操作。普通混音录音不再依赖通话专用音频路径；外放且开启语音打断的回声表现需要真机复验，不能宣称与原回声处理等效。

CoreDevice.error 在 vendor 边界保留为 plist 结构，不再先格式化成任意字符串；固定诊断提取最多三层 domain/code/NSUnderlyingError（含 userInfo 内的标准字段）。不记录 description、任意 userInfo、屏幕、语音、配对凭据。缺失字段、无效形状、链截断均显式标记。错误分类仍为 108/1，新增 peerNDomain/peerNCode 用于区分真实设备端错误；这两个编号不能与 Apple NSError 混淆。

同一独立日志 Documents/ncm-protocol-events.log 在请求回执处附加实际 appState、audioCategory、audioMode、audioOptions、inputAvailable、otherAudio（inputAvailable 只表示输入可用，不代表正在采集）。日志同时按 1000 行和 512 KiB 淘汰旧记录，避免较长错误链导致写满后阻断正常操作。存储失败仍可见，不添加自动重连、重配、视频重试或输入重放。

验证：Mac 语音状态机 21/21；Rust 视频协商/结构化错误链 5/5；使用真实 Swift journal 源码的主机检查通过（错误链、非法字段、注入、文件失败、字节上限轮转）；签名 iPhoneOS build 与 codesign --verify --deep --strict 通过。未启动模拟器、未代执行真机任务。

已通过 wired USB 安装并普通启动 175phone 的 com.y175.orva；安装序列 2416。构建包含新 Swift 音频实现和重编译的 idevice/backend，二进制已确认新诊断标记存在。证据 .build/orva-voice-media-rust-tests.log、.build/orva-voice-media-voice-tests.log、.build/orva-voice-media-signed-build.log、.build/orva-voice-media-install.json、.build/orva-voice-media-launch.json。真实语音任务视频启动是否恢复仍待用户在新版复验。


## 9022 确认与移除语音打断（2026-10-14 23:00）

- 22:49:28 真机日志确认 `com.apple.dt.CoreDeviceError / 9022`，请求 9ms 被拒；上一版 `.default + mixWithOthers` 已生效，但未释放麦克风，不能解决传感器占用冲突。此前“音频模式修正”的验证不能作为问题已恢复的结论。
- 用户明确要求执行时不用麦克风/音频并取消打断功能。现在 VoiceSession 同步停止输入、识别、播放并停用音频会话后，才提交任务；释放失败不提交。移除打断开关、口令解析和待执行更正队列。
- 语音轮次选择纯系统后台调度，既不接受录音作为执行凭据，也不借 PiP/静音播放替代系统授权。UIKit 有限授权覆盖切换，BGContinuedProcessingTask 是否获批/过期写入后台日志；有效授权结束即停止任务，不承诺无限后台时间。
- 保留任务系统授权直到屏幕控制清理结束。完成后输出专用播报、不启用麦克风；播报结束再检查实时活动并启动全新录音 epoch。旧录音/播报回调不能发送新任务。手动结束期间仍等待任务清理完成。
- 新日志：`voice.audio mode=capture/released/playback`（真实 engineRunning/tapped/sessionOwned）、`voice.audioReleased reason=execution`、`execution.voice policy=systemOnly audio=false`、`voice.turnStarted`、`voice.runDrained`。不保存语音原文、录音或模型答复。
- 本轮验证：Mac 主机语音状态机 18 项通过；未运行模拟器。真机构建/安装结果以本轮日志和安装回执为准，实际回环任务需用户复测。


## 不打开 App 的 LongRunningIntent 后台入口（2026-10-14 23:25）

23:06 与 23:08 真实日志已证明执行时释放音频后，视频协商、OCR、截图均成功；随后失败来自 `BGContinuedProcessingTaskRequest` 被拒及 UIKit 临时授权约 30 秒到期。旧入口启动录音后立即返回，后续模型任务不在 App Intent 的执行作用域内。

按用户要求不进行前台交接、不恢复执行期音频。核对本机 iOS 27 SDK 与 Apple 的 LongRunningIntent 文档后，系统「ORVA 语音任务」/「开始语音任务」改为 AudioRecordingIntent + LongRunningIntent + CancellableIntent。performBackgroundTask 的 operation 从启动一直 await 到语音结束、任务与屏幕清理完成；只有实际进入此 operation 才激活执行 scope。该 scope 给语音轮次发放独立 lease，不启动 ContinuedProcessingScheduler / UIKit 临时倒计时，不用定时器续命。App 内普通语音入口仍走其独立系统调度，不能通过直接调用 perform 冒充系统授权。

进度为未知总步数，只有实际模型响应/工具回执增加计数；阶段变化只更新说明，不用心跳伪造进度。重复回执不增计数，计数倒退记录不变量错误并撤销。系统取消可在 operation 进入前锁住 pending scope；开始后立即停止语音及后续输入，等待清理，不重放已发出的未知动作。旧 scope 的迟到取消不影响新会话。结束时保留语音会话占用至 worker drain，防止清理期间启动新任务。

新增诊断 `execution.intentGranted`、`execution.intentLease`、`execution.intentProgress`、`execution.intentClosed`、`voice.intentCancelled`、`voice.intentExecutionFailed domain/code`，用 scope UUID 关联，未记录语音、截图、模型正文或凭据。系统申请拒绝明确抛错，不打开 App、不自动切换到音频保活。

验证：真实 scope + RunLifecycleCoordinator 的 Mac 主机 9 项测试通过；既有语音状态机 18 项通过。未启动模拟器、未自动发起录音或手机任务。真机后台授权是否实际延长仍待用户从操作按钮复测；编译通过不能代替真实授权和端到端任务验收。

来源：https://developer.apple.com/documentation/appintents/longrunningintent 、https://developer.apple.com/documentation/appintents/longrunningintent/performbackgroundtask(options:operation:oncancel:) 。

最终签名 iPhoneOS build 与 codesign --verify --deep --strict 通过；USB 覆盖安装到 175phone 成功，com.y175.orva，安装序列 2432，容器 B941EFDC-0507-412E-A865-E28DCBFAF8E0。本轮未调用启动 App、模拟器或真实任务。证据：.build/orva-long-intent-final-build.log、.build/orva-long-intent-voice-tests.log、.build/orva-long-intent-install.json；9 项 scope/lifecycle 主机测试记录在本会话 work/long-intent/host-tests.log。


## A 方案接入正式任务（2026-10-15）

用户确认独立实验 A 可用、B 不可用后，选择 A。独立实验中，175phone 的系统 Intent 后台启动 A，60/60 个实际计算步骤完成，用时约 124.848 秒；B 的后台提交被拒绝。这不是长期运行、锁屏、冷启动或跨 App 正式任务的全面验收。

- VPN/NCM 的真实任务选用独立的 LocationRunScheduler；每个片段持有自己的 CLLocationManager，避免旧取消影响新任务。使用与实验 A 相同的 reduced accuracy、关闭自动暂停和显示系统定位指示配置。坐标不进入模型、日志或持久化。
- 首个定位回调前不允许后台步骤发送，20 秒未收到回调即明确失败。定位错误、权限撤销或系统暂停停止任务，保留未知输入结果，不自动重试或切换回音频、LongRunningIntent、B。
- “开始语音任务”保留 AudioRecordingIntent/LiveActivityIntent 与录音期间实时活动要求；录音启动完成后返回，由单例语音会话和每轮任务分别管理生命周期。移除 LongRunningIntent 绑定与其取消路径。
- 执行阶段仍先释放麦克风和音频；结束屏幕会话后释放定位，再由既有语音流程播报答复并恢复聆听。用户结束或锁屏立即撤销后续动作和定位。旧后台常驻音频设置不再激活播放。
- ORVA「设置 → 后台执行」提供定位权限状态、分阶段申请及打开系统设置。ORVA 与独立实验 App 的权限分别授权；需要给 ORVA 设为“始终”，不要求精确位置。
- 新增定位生命周期回归：权限拒绝、首回调等待、超时、运行中失败不自动重启、晚到回调、多个片段隔离、未知结果不重放、旧常驻设置不启动音频。保留默认 target 的全部已有核心覆盖。

验证与安装结果待本轮构建完成后补充。

参考：[后台定位配置](https://developer.apple.com/documentation/corelocation/cllocationmanager/allowsbackgroundlocationupdates)、[Always 权限](https://developer.apple.com/documentation/corelocation/cllocationmanager/requestalwaysauthorization())、[AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent)。

## 内置 VPN 与户外初始化解耦（2026-10-15）

新增纯 Swift `ORVAConnectionKit`，独立承载回环配置、IPv4 回注与户外初始化状态机；Network Extension、现有配对后端、执行凭据、App Intent 和 SwiftUI 均通过适配层接入。Agent 不负责 VPN 生命周期，UI 重构无需修改连接核心。三个 App Intent 配合包内签名快捷指令实现准备、离线建链、恢复后验证，已有可验证连接直接复用；首次添加 VPN 和快捷指令仍由用户在手机上确认。

核心连接测试 15 项、App 核心测试 469 项全部通过；无签名/签名 iPhoneOS 构建、App 及 VPN 扩展深度签名校验通过。175phone 通过无线连接安装成功，安装序列 2496；未执行用户真实任务或自动切换手机网络。完整手机操作与边界见 [连接模块指南](ORVA-CONNECTION.md)。自动户外流程仍待真机验收，不能以构建、安装或此前手动流程成功替代。

### 内置快捷指令 v2 文本变量修正

用户导入后发现编号/回执为空，并确认手动绑定可用。定位为 v1 在文本参数使用了 `WFTextTokenAttachment`；本机 Apple 文本解析器返回空状态。改用 `WFTextTokenString` 后，编号、回执及显示结果三个参数保留上游输出 UUID 且序列化往返一致。补充主机解析器回归检查及签名前变量引用校验，未改 VPN/配对/Agent 执行逻辑。v2 已重新签名并核对 App 包内资源，无签名/签名构建和深度签名校验通过，无线安装成功，序列 2504。没有修改用户已导入的快捷指令副本，新模板再次手机导入的界面待确认；本次未启动模拟器。
