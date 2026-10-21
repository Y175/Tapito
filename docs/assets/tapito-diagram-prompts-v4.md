# Tapito README diagrams — image2 prompts

日期：2026-10-21。

使用内置 image_gen 工具生成与编辑；未使用 CLI 或自定义绘图脚本。两图为中英双语，共用于中英文 README。

- [系统架构图](tapito-architecture-v4.png)
- [任务执行流程图](tapito-execution-flow-v4.png)

## 内容核对

- 普通执行与 Jev 协同共用主 Agent；主 Agent 决定上下文、技能、完整输入值及最终答复。
- Jev 仅选择阶段内的操作与 OCR 目标；阶段完成、缺少输入、受阻或预算用尽时交回主 Agent。
- Jev 接收文字；主模型在必要时查看截图。
- 所有设备动作经过 iOS 适配与连接/协议层；后台资格由 iOS 管理。
- 个人记忆与操作知识分开；异步学习不阻塞回复，页面/流程候选经审核后用于后续任务。
- 流程图修订了交回箭头，并移除了会被误读为必经步骤的“已审核流程可复用”注释框；复用能力仍由架构图和 README 正文说明。

## Architecture — generation prompt

```text
Use case: infographic-diagram.
Create a polished publication-quality raster diagram for the Tapito open-source GitHub README using image2. Brand palette: violet #6554F5, turquoise #24BEB4, near-black #192033, pale lavender panels on a warm white background. Flat editorial design, extremely crisp typography, generous spacing, precise thin orthogonal connectors and arrowheads, restrained line icons, no 3D, no glow, no stock graphics, no gradients that reduce contrast. Landscape 3:2, high-resolution preferably 3072x2048. English and Simplified Chinese text must be spelled accurately, aligned on a strict grid, no tiny paragraphs. Use Chinese primary labels with short English secondary labels where specified. The diagram must remain legible at README width. Do not include experimental/trial labels, M1-M5 numbering, performance metrics, fabricated functionality, or a second independent whole-task Jev agent. No watermark.
Primary request: Draw Tapito's CURRENT SYSTEM ARCHITECTURE. Top-left wordmark "Tapito" and small violet orbital cursor mark; title "系统架构" with subtitle "SYSTEM ARCHITECTURE". A concise, spacious engineering architecture diagram; illustrate RESPONSIBILITY BOUNDARIES, not every algorithmic step.

Layout and exact labels:
TOP across the width, two stacked horizontal bands:
- "入口与展示 / ENTRY & PRESENTATION": below, "聊天 · 语音 · 快捷指令 · 操作按钮" and small "Chat · Voice · Shortcuts · Action Button". At its right end a compact "灵动岛 / Dynamic Island" status chip.
- "iOS 宿主 / iOS HOST": "权限 · 依赖装配 · 后台生命周期" and "Permissions · Composition · Task lifetime". Tiny module annotation "Tapito · TapitoVoiceKit · TapitoLiveActivity".
A clear downward arrow from entry to host, then from host into the main central core. A dashed outward arrow from core back to presentation labeled "状态与耗时 / Events & timing".

CENTER row, three columns:
LEFT a smaller knowledge panel titled "技能与记忆 / KNOWLEDGE", with three separated rows "App 技能 / App skills", "个人记忆 / Personal memory", "已审核操作 / Reviewed operations". Beneath it a small dashed card "异步学习 / Async learning" and small text "页面与流程候选需审核 / Review operation candidates"; connect learning to the knowledge panel. Personal memory and reviewed operation knowledge are distinct.
MIDDLE the largest violet-outlined container titled "TapitoAgentKit" with subtitle "独立 Agent 核心 / UI-independent core".
Inside: largest top card "主 Agent / Main Agent" and a small line "上下文 · 技能 · 输入值 · 最终答复" / "Context · Skills · Input values · Final answer".
Below, two compact side-by-side cards: "工具执行 / Tool execution" and "Jev 阶段执行 / Jev stage execution". Main Agent directs both. Label Main-to-Jev arrow "delegate_screen"; show Jev's evidence returning UP to Main with a small "阶段结果 / Stage evidence". The Jev stage executor uses the same underlying device tools; it is inside this core, never an independent task owner. Label the short shared bottom connector "观察 · 操作 · 回执 / Observe · Act · Receipts". Core sends a dashed arrow to the async-learning card labeled "任务记录 / Run evidence".
RIGHT smaller service panel titled "模型服务 / MODEL SERVICES", text "ProviderKit", with two distinct rows "主模型 / Main LLM" and "TypeSafe Jev". A single bidirectional connector between core and services labeled "请求与决策 / Requests & decisions".
A simple bidirectional connection joins KNOWLEDGE and core.

BOTTOM across the width, three stacked bands, each with a clear downward arrow:
- "iOS 执行适配 / DEVICE ADAPTER": "本机 OCR · 截图 · 触控 · 整段输入 · 启动 App" / "Local OCR · Screen · Touch · Text · Launch".
- "连接与协议 / CONNECTION & PROTOCOL": two horizontally adjacent subcells: "TapitoConnectionKit" / "本机 VPN · 户外初始化" / "Local VPN · Outdoor setup"; and "TapitoNCM + Rust" / "配对 · 开发者服务 · 屏幕与输入" / "Pairing · Developer services · Screen & input".
- slim terminal band "iPhone 系统与第三方 App" / "iPhone system and third-party apps".
Footer in small but readable type: "OCR 在本机运行；模型请求发送到所配置服务。后台执行由 iOS 管理。" / "On-device OCR. Configured model services. iOS-managed execution lifetime."

Critical semantics: one shared Main Agent owns ordinary tools and Jev delegation, Jev receives OCR text only, all actual UI actions go through device adapter/connection, learning is asynchronous and operation activation requires review. No direct Knowledge-to-phone arrow. No direct Jev-to-final-answer arrow. Prefer fewer clean connectors over criss-crossing arrows. Render only the specified content, with visual grouping and hierarchy.
```

## Task execution — generation prompt

```text
Use case: infographic-diagram.
Create a polished publication-quality raster diagram for the Tapito open-source GitHub README using image2. Brand palette: violet #6554F5, turquoise #24BEB4, near-black #192033, pale lavender panels on a warm white background. Flat editorial design, extremely crisp typography, generous spacing, precise thin orthogonal connectors and arrowheads, restrained line icons, no 3D, no glow, no stock graphics, no gradients that reduce contrast. Landscape 3:2, high-resolution preferably 3072x2048. English and Simplified Chinese text must be spelled accurately, aligned on a strict grid, no tiny paragraphs. Use Chinese primary labels with short English secondary labels where specified. The diagram must remain legible at README width. Do not include experimental/trial labels, M1-M5 numbering, performance metrics, fabricated functionality, or a second independent whole-task Jev agent. No watermark.
Primary request: Draw Tapito's CURRENT TASK EXECUTION FLOW, visually matching the described violet/teal editorial architecture design. Top-left wordmark "Tapito" and small violet orbital cursor mark; title "任务执行流程" with subtitle "TASK EXECUTION". One shared main Agent loop with an optional Jev delegated sub-loop. Make the execution path and return paths unambiguous. This is a current software flow, not a marketing illustration.

Composition: top center user and main-agent cards; beneath them two action lanes; then one centered verification diamond, final answer, and a bottom dashed asynchronous-learning lane. Use plentiful margins around loop-back arrows. Landscape 3:2 high resolution. No numbered M labels.

Exact labels and edges:
1) Top slim card "用户任务 / User task", small "本轮请求与有效上下文 / Request & valid context".
Down arrow to prominent violet card "主 Agent 决策 / Main Agent", small "按需加载技能与记忆；确定阶段目标和输入值" / "Skills · Memory · Stage goals · Exact input".
2) From Main split into TWO clearly labeled branches:
LEFT branch label "直接 tool call / Direct tools". Teal lane with:
  "执行设备工具 / Execute tools"
  below it "启动 App · 点击 · 滑动 · 整段输入" / "Launch · Tap · Swipe · Type"
  down arrow to "观察与回执 / Observe & receipts"
  small "本机 OCR；必要时主模型查看截图" / "Local OCR · Main-model vision when needed"
  A separate subtle annotation within this left lane: "已审核流程可复用 / Reviewed operations can be reused". No extra model needed for every OCR decision.
RIGHT branch label "delegate_screen / 阶段委派". Pale violet outlined sub-loop titled "Jev 协同 / Jev collaboration".
  First a tiny context caption "阶段目标 · 完成条件 · 完整字段值" / "Goal · Completion · Exact input".
  Three small stacked cards connected down: "本机 OCR / Local OCR" then "Jev 选择操作与目标 / Choose operation & target" then "执行动作 / Execute action". A short curved/orthogonal arrow from Execute action back to Local OCR labeled "重新观察 / Observe again". From the choose card an EXIT arrow to a separate card below the loop labeled "交回阶段证据 / Return stage evidence". Its small caption "完成 · 缺输入 · 受阻 · 达到预算" / "Done · Need input · Blocked · Budget".
  Place note "Jev 只接收文字 / Jev receives text only" inside this lane, and note "阶段结束不等于任务完成 / Stage done ≠ task done" near its exit.
3) Both the left "Observe & receipts" and right "Return stage evidence" arrows merge into a centered violet diamond "主 Agent 核验 / Main Agent verifies" with the question "用户目标是否完成？ / Task complete?".
  A strong loop arrow labeled "继续 / Continue" from diamond's NO/NOT YET side goes around the outside back to the TOP Main Agent card. Must terminate at Main Agent, not at user.
  A downward YES arrow labeled "已完成 / Complete" from diamond goes to "依据结果回答 / Evidence-based answer".
4) Below final answer, connect by a thin DASHED arrow labeled "启用时入队，不阻塞回复 / Enqueue when enabled" to a pale dashed horizontal box titled "异步学习 / ASYNC LEARNING". Within this box show two separated outcomes: "个人记忆 / Personal memory" and "页面与流程候选 → 审核 → 后续任务复用" / "Operation candidates → Review → Later reuse". No learning-to-current-action arrow.
5) Bottom footnote strip, not part of normal success path: "连接失败或送达结果未知：停止并保留回执，不重放输入。" / "Connection failure or uncertain delivery: stop, keep receipts, do not replay input."

Critical invariants: Main Agent decides exact input content and final answer. Jev handles only a bounded stage from OCR text and returns evidence. It cannot end the whole task. Main Agent may call screenshot for icons or missing visual state. Reviewed operations still use current local page checks. Async learning cannot block the answer. Arrow routing must be clean and correct, no ambiguous self-loop into final answer, no extra termination after OCR, no fabricated results. Favor these short labels and functional whitespace over decorative filler.
```

## Task execution — first edit

```text
Edit this Tapito task-execution diagram. Preserve the existing typography, colors, title, icons, bilingual text, major nodes, canvas size, and overall layout. Change ONLY these two connector issues, while maintaining beautiful spacing:

1. In the right Jev collaboration lane, the "交回阶段证据 / Return stage evidence" exit must originate from "Jev 选择操作与目标 / Choose operation & target", NOT from "执行动作 / Execute action". Remove the existing vertical arrow from Execute action down into Return stage evidence. Instead route a distinct purple orthogonal arrow from the LEFT edge of Choose operation & target, around the left side of the action card, then down into Return stage evidence. Label this exit subtly "交回 / Handoff". Preserve the Choose-to-Execute downward arrow AND the Execute-to-Local-OCR loop. Meaning: Jev can either choose to execute an action and observe again, OR return a stage result WITHOUT sending an action.

2. In the left lane, "已审核流程可复用 / Reviewed operations can be reused" is an OPTIONAL NOTE, not a required process step. Remove arrow connections entering or leaving that note. Keep the note in the left panel as a visibly secondary annotation. Draw the path directly from "观察与回执 / Observe & receipts" to the Main Agent verification diamond, routing around the note. Keep Execute tools -> Observe & receipts unchanged.

Do not change any other edges or wording. The verification NO loop must still return to the top Main Agent, YES must lead to the final answer, and the final answer must still have the dashed nonblocking learning connection. All connectors must terminate clearly and avoid text.
```

## Task execution — final edit

```text
Edit the supplied Tapito flowchart; keep all other graphics and text unchanged. Make exactly TWO localized fixes.
A. LEFT lane: DELETE the entire optional dashed box labeled "已审核流程可复用 / Reviewed operations can be reused" and its icon. It is unnecessary. Shorten the surrounding pale teal lane to end just below the "观察与回执 / Observe & receipts" card. Draw ONE continuous teal connector starting at the BOTTOM CENTER of the Observe & receipts card, going vertically down to the existing lower bend, then right into the LEFT point of the "主 Agent 核验 / Main Agent verifies" diamond. This connector must visibly TOUCH both the observation card and the verification diamond, with an arrowhead only at the verification diamond. Do not leave a floating disconnected line.
B. RIGHT lane: the purple connector labeled "交回 / Handoff" begins at the LEFT edge of the "Jev 选择操作与目标 / Choose operation & target" card and flows left, then down, then right/down into the "交回阶段证据 / Return stage evidence" card. REMOVE the small arrowhead(s) currently pointing INTO the left edge of Choose operation & target. Keep a plain line attached there as the source. Keep ONLY the arrowhead pointing DOWN into Return stage evidence as the destination. This must be a ONE-WAY exit from Choose to Return.
Preserve the other arrows: OCR to Choose, Choose to Execute, Execute loop back to OCR, Return to verification, verification NO to Main Agent, verification YES to answer, answer dashed to async learning. Preserve all text, colors, spacing outside the requested local edits.
```
