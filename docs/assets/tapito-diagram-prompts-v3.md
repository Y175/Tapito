# Tapito 架构图与任务流程图 · v3

日期：2026-10-19。

使用内置 image_gen 工具生成两个全新图像，再各进行一轮连线修正。未引用旧版图片。用户指定 image2；内置接口未暴露可选择或独立核验的模型版本，因此这里仅记录实际使用的工具，不将具体模型版本作为已核验事实。

当前实现依据：`AgentSessionController.swift`、`HarnessAgentEngine.swift`、`HarnessTools.swift`、`JevOCREngine.swift` 和当前连接模块。普通 Agent 按需加载技能并通过 Tool Call 循环执行；Jev 是独立的 OCR 候选选择流程，不上传图片、不进入自动学习队列。页面学习在启用后异步入队，审核后供后续任务使用。

最终图：

- [系统架构](tapito-architecture-v3.png)
- [任务执行流程](tapito-execution-flow-v3.png)

人工检查：中文标签、两个互斥模式、知识模块仅接入普通 Agent、执行后重新观察、结束路径绕过执行、UI 与连接边界。未运行应用测试；本轮只更新图片与 README 展示。

## 架构图初始提示词

```text
Use case: infographic-diagram.
Create a completely NEW, polished Chinese software architecture diagram for the GitHub README of Tapito, an iPhone automation assistant. This is a standalone finished diagram, not a photo or a mockup. Do not use any earlier conversation images, compositions, icons, shapes or color systems as references. Do not draw M1, M2, M3, M4, M5, M6, M7 anywhere, or the obsolete WorkflowAgentEngine, or a route_task gate.
Canvas: high-resolution landscape, approximately 3:2 ratio. Fresh editorial design: near-white background, deep ink typography, exceptionally readable simplified Chinese sans-serif. Flat geometric module panels, generous margins and spacing, restrained jade for execution, indigo for intelligence, amber for learning, slim precise connectors with clear arrowheads. No decorative phone screenshots, robot, brain, planets, 3D, stock illustration, gradients, fake code, or watermark. Use a restrained typographic Tapito wordmark. Information architecture and clear boundaries are the design.
Title exact: "Tapito · 系统架构"
Subtitle exact: "自然语言任务 → 模型决策 → iPhone 操作"

Compose a clearly layered CENTER architecture with a RIGHT SIDEBAR for independent external services and local knowledge. Keep most type large; supporting text short. Chinese text must be accurate and unclipped.

TOP band:
"入口与展示"
two balanced groups "任务入口：文字 · 语音 · 快捷指令 · 操作按钮" and "状态反馈：聊天界面 · 灵动岛 · 步骤耗时"
A downward arrow labelled "提交任务"; a distinct upward arrow labelled "订阅事件" to the layer below.

NEXT band:
"iOS 宿主"
"依赖装配 · 系统权限 · 后台运行资格 · 语音会话"
This connects to central Agent core. No direct model-to-UI or model-to-phone arrows.

CENTRAL largest boundary labelled "独立 Agent 核心" with small package name "TapitoAgentKit".
Two equally important side-by-side engine modules inside, explicitly alternative selected modes, not sequential stages:
LEFT module: "普通 Agent" / "模型选择 Skill 与 Tool Call" / "按需使用 OCR、图片与已学习能力"
RIGHT module: "Jev OCR · 试验" / "从 OCR 动作候选中选择最高概率项" / "仅文字输入 · 不上传图片"
Above both a short label "每次任务选择一种执行模式".
Both connect down to a shared horizontal module inside core:
"统一工具执行"
"参数与帧校验 · 串行执行 · 操作回执 · 停止取消"
Small bottom boundary note "UI、模型和连接通过接口接入".

RIGHT SIDEBAR aligned with central core has TWO separated modules:
Upper external module "模型服务" with "通用模型接口" and "TypeSafe Jev 接口"; bidirectional thin connection to the two engine modules labelled "请求 / 决策". The endpoints are model adapters, not controllers of the phone.
Lower local module "技能与长期记忆" with short lines "通用技能 + App 专属技能" / "个人记忆 · 页面控件 · 操作流程" / "执行证据 → 异步分析 → 页面能力审核".
Use a solid connection from this knowledge module to ONLY the "普通 Agent" module labelled "按需加载".
Use a dashed connection from the ordinary Agent to knowledge labelled "启用学习时入队".
Small note within knowledge module exact: "Jev 当前不接入自动学习".
Make these arrows clear and separate; do not suggest the normal-mode knowledge pipeline applies to Jev.

BENEATH CORE aligned with center, connected downward from shared tools:
"iOS 执行适配"
"本机截图 / Vision OCR · 点击 · 滑动 · 整段输入 · 启动 App"
BENEATH that:
"独立连接服务"
"内置本机 VPN · 配对认证 · 屏幕与输入通道 · 户外初始化"
small package line "TapitoConnectionKit · TapitoNCM · Rust"
BOTTOM endpoint:
"iPhone 开发者服务 → 系统 App / 第三方 App"

Bottom narrow footnote, separated by a hairline:
"图片与文字按模式发送给模型；后台执行受 iOS 生命周期约束。"
No test numbers, speed claims, commercial claims, version badges or legacy stage numbers. Keep long text wrap intentional. Ensure the core, device adapter and connection service are separate boundaries. Produce only this architecture diagram.
```

## 流程图初始提示词

```text
Use case: infographic-diagram.
Create a completely NEW Chinese execution-flow diagram for the GitHub README of Tapito. Finished diagram only, no photo or mockup. Do not use any previous images in the conversation as references. Do not include any M-number model-stage labels or obsolete route_task/WorkflowAgentEngine. The diagram describes actual implementation, not a proposed fixed seven-model pipeline.
Canvas high resolution, landscape approximately 3:2 or 4:3, large crisp simplified Chinese type. Fresh restrained editorial design with near-white paper background, deep ink text, indigo model decisions, jade local tools, amber async learning, light coral exception strip. Flat modules, precise orthogonal arrows, generous whitespace, no crossing arrows, minimal rounded corners, no decorative screenshots, robots, 3D, watermark or invented metrics.

Title: "Tapito · 任务执行流程"
Subtitle: "模型决定下一步，程序执行并返回真实结果"

TOP centered start node:
"接收任务" / "文字、语音或系统入口"
Arrow to "使用本轮选定模式".
Split evenly into TWO parallel vertical lanes. They are alternative modes, never fallbacks or sequential stages. There must be NO arrow from Jev to the ordinary Agent.

LEFT lane header "普通 Agent · Tool Call 循环"
Five core stages top-down, each sufficiently separated:
1 "准备上下文" with "任务 · 会话 · 相关记忆 · 技能目录 · 可用工具"
2 INDIGO "模型选择下一步" with "按需加载通用 / App 技能"
3 JADE "执行 Tool Call" with "查询 / 启动 App · 观察 · 点击 / 输入" and "已审核页面与流程也可作为工具调用"
4 JADE "返回观察与操作回执" with "页面操作后自动本机 OCR" and "文字不足时按需调用截图工具"
A clear loop arrow along the left outer edge from stage4 back to stage2, labelled "继续任务"; keep arrowhead unambiguously entering stage2. Small inline note adjacent to stage4: "已核验页面能力可复用；无需另问是否 OCR".
A separate exit arrow directly from stage2, labelled "无需继续调用工具", goes to the lane's bottom output:
5 "根据当前证据回复" with small "普通问答可直接完成".
All tools including skill loading feed results back into the same model loop; this is NOT a mandatory script that always opens an app or always takes a screenshot. Clarify visually with the loop.

RIGHT lane header "Jev OCR · 试验循环"
Stages top-down:
1 "选择目标 App" with "已安装目录 → Jev 选择 → 按需启动"
2 JADE "本机截图并 OCR" with "文字 · 候选 ID · 坐标 · 识别置信度"
3 INDIGO "Jev 选择动作" with "任务 + 当前 OCR + 最近操作" / "直接取最高概率项"
4 JADE "绑定候选并执行" with "点击 · 滑动 · 等待 · 提取原文输入"
Loop arrow on the right outside edge from stage4 back to stage2 labelled "每步重新观察".
Separate exit arrow from stage3 labelled "选择结束" goes to output:
5 "返回当前屏幕文字"
A short note within the Jev lane: "不上传图片 · 不设置信度阈值 · 不调用第二个模型复核".
A smaller note: "文字无法支撑操作时明确结束".
No visual-model fallback arrow. Do not imply model-generated arbitrary coordinates; local candidate binding determines click location.

BENEATH the LEFT output only, an amber dashed secondary branch, clearly NOT part of response critical path:
Title "异步学习 · 开启后运行"
"用户原话 → 个人记忆"
"操作证据 → 页面控件 / 流程候选 → 审核后供后续任务使用"
A dashed arrow from left output into this panel labelled "入队，不阻塞回复".
Beneath right output a small neutral footnote "Jev 当前不接入自动学习".

FULL-WIDTH bottom policy strip, visually outside both lanes, no tangled error edges:
"共同执行约束"
"使用当前帧与有效连接；记录每步耗时；用户停止、协议失败或执行结果未知时结束，不重放已发送操作。"
Very small but readable extra statement: "普通 Agent 可纠正未发送的参数错误或页面偏离；不将对话结束等同于动作成功。"

No M1–M7, numeric fake progress or fictional execution guarantees. Keep core labels large and readable at GitHub README width. Only this flowchart.
```

## 架构图连线修正

```text
Edit this newly generated Tapito architecture diagram. Preserve title, all accurate text, typography, light flat style, modules, and overall visual quality. Correct connections and relocate ONLY the knowledge sidebar if necessary.
CRITICAL 1: The current amber "按需加载" arrow incorrectly points into Jev. Move the entire "技能与长期记忆" panel to a LEFT SIDEBAR alongside the ordinary Agent, outside the core boundary; keep "模型服务" in the RIGHT SIDEBAR. Shrink/rebalance the core to fit these three zones cleanly, with enough readable text space. The solid amber knowledge arrow must point directly into "普通 Agent", NEVER into "Jev OCR". The dashed amber evidence arrow must originate directly from "普通 Agent" and point to knowledge, label "启用学习时入队". Show an obvious gap separating these connections from the Jev module. Keep the note "Jev 当前不接入自动学习".
CRITICAL 2: Between "iOS 宿主" and "独立 Agent 核心" show a clear bidirectional connection for task submission and state events, not just a lone upward arrow.
CRITICAL 3: Add the missing downward arrow from "独立连接服务" to the "iPhone 开发者服务 → 系统 App / 第三方 App" endpoint.
Preserve both ordinary Agent and Jev as alternative modes, both connected downward to the shared execution module. Model services connect bidirectionally to the Agent core. Do not invent or add numbered model stages. All text must remain readable, no crossing connectors. It is acceptable to increase canvas width or height to give these corrected relationships sufficient room. Output only the corrected architecture.
```

## 流程图连线修正

```text
Edit this newly generated Tapito workflow diagram. Keep the title, all node text, two alternative lanes, learning panel, footer, colors and typography. Fix the arrow topology; this is critical and must be exact. Redraw connectors cleanly with ample whitespace. Never attach a "done" label to an execution arrow.

LEFT ordinary Agent:
- "准备上下文" → "模型选择下一步".
- "模型选择下一步" → "执行 Tool Call", arrow label "调用工具".
- "执行 Tool Call" → "返回观察与操作回执".
- "返回观察与操作回执" has ONLY a loop arrow back to "模型选择下一步", label "继续任务". DELETE the direct downward arrow from "返回观察与操作回执" to "根据当前证据回复": tool completion must not directly finish a task.
- A separate bypass along the INNER RIGHT side of the left lane connects "模型选择下一步" directly to "根据当前证据回复", label "无需继续调用工具". Put this label alongside that bypass, not over the tool execution arrow.
- Keep reply → dashed learning queue arrow.

RIGHT Jev:
- "选择目标 App" → "本机截图并 OCR" → "Jev 选择动作".
- "Jev 选择动作" → "绑定候选并执行", label "执行动作".
- ONLY "绑定候选并执行" → loop back to "本机截图并 OCR", label "每步重新观察". Move the existing loop origin away from "Jev 选择动作" so it visibly attaches to the execution box. A choice alone is not an action.
- DELETE the arrow from "绑定候选并执行" to "返回当前屏幕文字".
- Draw a distinct bypass along the INNER LEFT edge of the right lane from "Jev 选择动作" directly to "返回当前屏幕文字", label "选择结束". This must not go through execution. Place the label next to bypass, never between choice and execution.
If necessary widen the diagram and adjust card widths to make both bypasses and both loops absolutely clear. Use uninterrupted paths with obvious arrowheads at node borders. Do not add any connection between the two lanes. Do not alter factual content or add M-number stage labels.
Final output only the corrected flow diagram.
```
