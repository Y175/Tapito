# Tapito 架构图与流程图提示词 v2

日期：2026-10-16。生成方式：内置 image_gen 工具；两个独立的全新图像请求，无参考图片。用户要求使用 image2；工具接口不提供可独立指定或核验的模型版本参数，因此不把模型版本作为已核验事实。

内容依据：README 与 docs/Tapito-WORKFLOW-RUNTIME.md，并核对 WorkflowPrompts.swift。图示当前实现，不表示许可证迁移已完成。

## 架构图

```text
Use case: infographic-diagram.
Create ONE polished high-resolution architecture diagram for the real iPhone agent product Tapito. This is a final GitHub README image, not a mockup or photograph. Landscape 3:2 composition, approximately 3072x2048 or higher. Chinese text must be highly legible and correct. Design should feel like an excellent Apple developer conference systems slide crossed with a sophisticated technical publication: warm white background, charcoal typography, generous margins, restrained hairline grid, meticulously aligned cards, small precise icons, rounded corners, extremely subtle shadows. Program elements use cobalt blue; models violet; device connectivity teal; learning amber. Mostly clean flat design, not neon cyberpunk, no 3D blocks, no stock robot, no floating brain, no gradients behind text. A tiny black orbit/ring mark beside the Tapito wordmark is enough branding. The structure must be beautifully laid out and immediately understandable. No watermark, no license claims.

Top header: large "Tapito" and "模块架构". Subtitle: "程序主导执行 · 模型按需参与 · UI 与连接解耦". Small top-right tag "当前实现 / 2026.10".

Use a vertically layered system with a broad central core and a narrower provider card on its right. Clear arrows, no tangled crossings, no fake modules.
1. Top wide strip labeled "入口与展示". Show five evenly spaced minimal icons with exact labels: "聊天", "语音", "快捷指令", "操作按钮", "灵动岛". The legend under this strip reads "提交任务 / 订阅状态事件". A bidirectional thin arrow links it to the host.
2. Host wide card labeled "iOS 宿主", secondary exact identifier "AgentSessionController". Supporting line "依赖装配 · 权限与生命周期 · 持久化 · 事件桥接". This host connects down to the core, not directly to model responses.
3. Large prominent central bordered container labeled "独立 Agent 运行层" and "TapitoAgentKit". Inside arrange a precise 2x2 grid:
- "会话与执行契约" / "TapitoAgentCore" / "运行身份 · 状态 · 中立事件"
- "程序工作流" / "WorkflowAgentEngine" / "路由 · 分支 · 预算 · 取消"
- "工具调度" / "Tool Call" / "整批预检 · 串行执行 · 动作回执"
- amber "知识与学习" / "长期记忆 · 页面能力 · 技能版本" / "持久队列 · 证据核对 · 审核发布".
Inside, a clear path workflow -> tool dispatch, and knowledge -> workflow labeled "版本快照".
Alongside this container at the RIGHT, one violet provider card:
"模型适配" / "ProviderKit" / "M1–M5：在线任务" / "M6–M7：异步分析" / "供应商与模型按任务固定".
Connect workflow to provider bidirectionally. Connect knowledge to provider with a dashed arrow. Do NOT imply seven models are always called or that the queue runs indefinitely in background.
A compact label beneath the central container says "核心不依赖 SwiftUI / UIKit / 麦克风 / VPN API".
4. Beneath the core, teal full-width card: "iOS 执行适配" / "ActionCoordinator" / "截图 · Vision OCR · 页面核验 · 点击 · 整段输入". Tool dispatch connects down to this card.
5. Next teal card: "独立连接能力" / "TapitoConnectionKit · TapitoNCM · Rust 后端 · 本机 VPN" / "配对认证 · 屏幕会话 · 输入通道 · 户外初始化". Execution adapter connects down to this.
6. Bottom slim terminal with outlined phone icon: "iPhone 开发者服务 → 系统 App 与第三方 App". Connection connects to this. This must be the endpoint, no cloud phone illustration.
Footer small legend with the four colors: "程序 / 模型 / 设备 / 学习". Last footnote exact: "架构边界不等同于许可证边界；现存第三方声明仍需保留。"
Pay special attention to whitespace and Chinese character fidelity. Draw actual unambiguous diagram connections, not decorative random lines.
```

## 流程图

```text
Use case: infographic-diagram.
Create ONE polished high-resolution workflow diagram for the real iPhone agent product Tapito, matching a premium technical architecture publication. Landscape 3:2, approximately 3072x2048 or higher, with generous spacing and crisp readable Simplified Chinese. Warm white background, near-black type, careful Swiss editorial hierarchy, thin connector arrows, precise rounded cards. Flat and restrained. Program nodes cobalt blue; model nodes violet with clearly visible M-number badges; local device operations teal; asynchronous learning amber; stop/error nodes muted coral. Tiny black orbit/ring brand mark. No robots, no brains, no neon cyberpunk, no watermark. This is a truthful current implementation diagram, not a proposal. Do not invent features or performance claims.

Heading large: "Tapito 任务执行流程".
Subtitle: "已知步骤由程序执行，未知页面由模型协助；结果有证据，学习不阻塞".
Small tag "当前实现 / 2026.10".

Use clear numbered stages, a readable left-to-right top row, then TWO parallel vertical execution lanes, joining near the bottom, with an amber async learning band at the very bottom. At least 7% outer margins. All arrows must be unambiguous. Keep the two execution lanes visibly distinct, avoid crossing lines.

TOP ROW:
A blue "01 准备上下文" with small text "用户任务 · 权限 · 记忆 · 技能与能力快照"
-> violet "02 M1 理解与路由" / "结构化 route_task"
-> blue "03 程序校验与准备" / "解析 App · 装配技能 · 按需启动".
Below M1, two SMALL side exits clearly separated from device path:
"缺参数 → 澄清" and "普通问答 → M5 回答".
The device path from stage03 goes to decision diamond "已审核能力匹配？".
Left arrow labeled "是" enters left lane, right arrow labeled "否" enters right lane.

LEFT LANE pale teal panel titled "A · 已知页面能力":
- blue "冻结流程与控件版本"
- teal "当前画面本机核验" / "UI 样本 / 局部摘要；必要时 OCR"
- blue "按序执行已知步骤" / "当前位置 · 当前参数 · 授权与回执"
- teal "核对页面变化与结果".
Straight arrows down these four.
A side arrow out of page-check node labeled "页面偏离" goes to violet small box "M4 纠正剩余步骤", which goes to the shared Tool Call box in the right lane. DO NOT send protocol failures to M4.
A small note in this lane: "可跳过逐步 OCR 与模型调用，不能跳过当前画面核验".

RIGHT LANE pale violet/blue panel titled "B · 未知页面探索":
- teal "程序获取本机 OCR"
- violet "M2 / M3 规划与观察" / "文字足够即执行；歧义、图标按需同帧截图"
- blue prominent "Tool Call 执行器" / "完整批次校验 → 逐项授权 → 串行执行 → 回执"
- teal "输入后重新观察".
Arrows down. A single thin return-loop arrow from last node to M2/M3, labeled "尚未完成 / 预算内继续". From M2/M3 one exit "证据充分" goes to the completion join. Tool calls are selected by model but execution and validation are program responsibilities.
Small note: "没有单独一轮“问模型要不要 OCR”".

An ERROR EXIT card on the far right, coral:
"协议错误 / 动作结果未知" then "停止并记录诊断，不重发".
Connect from execution portions using labeled error arrows or one shared error rail. This must NOT lead to the success node or automatic retries.

Below both lanes a common blue completion strip:
"04 结果核验与回复"
Subline: "导航完成可由程序回复；动态内容与业务结果依赖当次证据，必要时 M5 整理".
Label successful paths entering the strip and then arrow to "返回用户".

At bottom, a distinct amber dashed boundary titled "05 持久异步学习 · 不阻塞当前回复".
A dashed arrow from the completion strip into "执行证据入队".
Then split into TWO small parallel cards:
violet-amber "M6 长期记忆" / "只依据用户明确原话，校验来源与版本".
violet-amber "M7 页面能力" / "固定 UI · 控件位置 · 功能 · 操作结果" / "坐标来自真实操作证据".
M6 leads to "个人记忆库". M7 leads to "证据核对 → 用户审核 → 能力库".
Short note at bottom: "页面模板不保存消息、联系人、热搜正文；后台被暂停则保留队列，恢复后继续。"
Small legend: "蓝：程序  紫：模型  青：设备观察  黄：异步学习".
Render arrows and Chinese exactly, prioritize logical correctness and legibility over decoration.
```

## 校正轮次：架构图

```text
Edit the provided Tapito architecture diagram. Keep the same excellent clean white publication style, Chinese labels, colored cards, aspect ratio and overall layout. Only correct dependency arrows and module boundary:
1. The central blue outline labelled TapitoAgentKit must enclose ONLY the four cards 会话与执行契约 / 程序工作流 / 工具调度 / 知识与学习. Move its right edge LEFT of the violet ProviderKit card, leaving ProviderKit visibly OUTSIDE this package boundary. Keep ProviderKit at the same right-side position and its two connecting arrows intact.
2. The short connector between iOS 宿主 and 独立 Agent 运行层 must be bidirectional, showing requests down and events up.
3. Replace the vertical arrow from 会话与执行契约 to 工具调度 with a clearly visible arrow FROM 程序工作流 TO 工具调度. Route it through whitespace, with a small label 调度, not through any text.
4. The downward connection to ActionCoordinator should come specifically from 工具调度, via an elbow arrow, not ambiguously from the entire container.
5. Replace the bottom-right legal footnote with the exact neutral caption: "按当前运行链路绘制 · 入口、Agent 与连接可分别演进". Keep the color legend.
6. Replace the brain icon in ProviderKit with a simple four-point star or geometric processor icon.
No extra boxes, no changed architecture claims, no additional long text. Chinese characters must stay correct, text razor sharp. Output only the corrected final image.
```

## 校正轮次：流程图

```text
Edit the provided Tapito workflow diagram. Preserve style, typography, colors, all stages, the two execution lanes and the bottom async-learning band. Correct the connector graph VERY precisely; the current arrows falsely skip observation and imply errors originate from success:
A. M4 纠正剩余步骤 must connect DIRECTLY to Tool Call 执行器, NOT to M2 / M3. Route its arrow through the white space between lanes then right into the LEFT EDGE of Tool Call. Avoid all text. Remove the existing M4-to-M2 horizontal arrow.
B. The blue return loop on the RIGHT of lane B must START at 输入后重新观察, and end at M2 / M3. Remove the existing loop from Tool Call directly to M2 / M3. Label new loop "观察结果 / 预算内继续".
C. Remove the blue success connection from 输入后重新观察 to stage04. That observation card should connect only back to M2 / M3. The right lane's completion route must START specifically at the LEFT EDGE of M2 / M3 with label "证据充分", go down the left inside edge of lane B, and enter 04 结果核验与回复.
D. Remove the long red line currently overlapping the blue completion rail above stage04. Errors must NOT originate from the successful result join. Keep just one neat red error arrow from the RIGHT EDGE of Tool Call to the coral STOP card, labeled "协议错误 / 动作结果未知". Remove red arrows from M2 / M3 if needed for clarity. Change the coral card text to "执行失败" and below it "停止并记录诊断，不重发".
E. Add a small coral text note below lane A: "同样遵守失败即停，不重放动作". This states its error semantics without a crossing red connector.
F. The blue success arrow from lane A's 核对页面变化与结果 to stage04 stays.
G. Preserve the OCR->M2/M3->Tool Call->输入后重新观察 vertical sequence. Preserve 04->返回用户 and dashed 04->M6/M7 learning path. Do not add a route from failure to success.
H. Make the note under lane B title clearly read: "没有单独一轮“问模型要不要 OCR”".
The entire diagram should fit cleanly with ample readable whitespace, no intersecting connectors that imply unintended branches. If necessary move cards slightly to make routing obvious. Output only the corrected image.
```

## 流程图连接线最终校正

```text
Make a precise minimal correction to the provided Tapito workflow diagram. Preserve ALL other content, colors, card positions and typography exactly.
Only fix these two connectors:
1. The teal card "当前画面本机核验" in left lane has an unconnected violet "M4 纠正剩余步骤" card immediately to its right. Add a blue horizontal arrow FROM the RIGHT edge of 当前画面本机核验 TO the LEFT edge of M4. Put the small label "页面偏离" above this new arrow. The existing M4 -> Tool Call arrow stays.
2. The connector labelled "证据充分" at the LEFT edge of the M2 / M3 card must be an OUTGOING success connector, not an incoming arrow. REMOVE the arrowhead currently pointing right into M2 / M3. Keep a plain line originating at the left edge of M2 / M3 going LEFT to the vertical rail, then DOWN toward 04. Keep only the downward arrowhead at the bottom of this success rail. At the intersection with the M4->Tool Call horizontal connector, insert a small bridge or gap to show the two routes do NOT join.
Do not add any other arrows. The correct closed loop OCR -> M2/M3 -> Tool Call -> 输入后重新观察 -> M2/M3 stays exactly as it is. Preserve all text and all cards. Output full corrected final image, not a crop.
```

## 已选用的项目资源

- `tapito-architecture-v2.png`：模块架构。ProviderKit 与 Agent 包分别标明；宿主上行线表示状态事件。
- `tapito-execution-flow-v2.png`：任务执行和异步学习。图中为主要路径，完整错误、预算和权限契约以 `../Tapito-WORKFLOW-RUNTIME.md` 为准。
- 两张图均已复制到本目录；README 不依赖图像工具的内部保存位置。
