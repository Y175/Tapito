# Tapito English README diagrams — image2 localization

Date: 2026-10-21.

Generated with the built-in `image_gen` tool (image2), using the inspected v4 diagrams as edit targets. No CLI or custom bitmap editing was used. The English editions preserve the architecture and flow while replacing every label with English and reflowing the typography.

| README | Architecture | Execution flow |
| --- | --- | --- |
| English | [English architecture](tapito-architecture-v4-en.png) | [English execution flow](tapito-execution-flow-v4-en.png) |
| Simplified Chinese | [Bilingual architecture](tapito-architecture-v4.png) | [Bilingual execution flow](tapito-execution-flow-v4.png) |

## Validation

- Visually checked all labels and captions for English localization and legibility.
- Preserved main-agent task ownership, optional Jev delegation, stage evidence handoff, verification loop and asynchronous learning.
- The English README references only the English diagram files; the Chinese README retains the original diagrams.

## Architecture localization prompt

```text
Use case: text-localization.
Asset type: English GitHub README architecture diagram.
Edit target: the supplied Tapito system architecture image. Produce its polished ENGLISH-ONLY edition using image2. Preserve the existing violet/teal palette, warm white background, flat line icons, strict grid, overall tiered layout, all architecture relationships and arrow directions, and Tapito branding. No Chinese characters anywhere. Remove bilingual duplication and make English labels substantially larger and clearer, reflowing within cards where needed. Do not leave gaps where Chinese was removed. Use generous whitespace and concise exact labels. Landscape 3:2, 1536x1024 or greater. No watermark.

Replace visible text with these English-only labels:
Top wordmark: "Tapito"; title: "System architecture".
Top band: "ENTRY & PRESENTATION"; "Chat · Voice · Shortcuts · Action Button"; right pill "Dynamic Island".
Second band: "iOS HOST"; "Permissions · Composition · Task lifetime"; module chip "Tapito · TapitoVoiceKit · TapitoLiveActivity".
Dashed return from core toward host/presentation: "Events & timing".
Left panel: "SKILLS & MEMORY"; rows "App skills", "Personal memory", "Reviewed operations".
Dashed lower left card: "Async learning"; smaller "Review operation candidates". Dashed core-to-learning edge "Run evidence". Learning points upward into knowledge.
Central main container: "TapitoAgentKit"; subtitle "UI-independent agent core".
Main card: "Main Agent"; caption "Context · Skills · Input values · Final answer".
Lower left card "Tool execution".
Lower right card "Jev stage execution"; delegation edge into it "delegate_screen"; return UP to main "Stage evidence". Add short text-only caption "OCR text only" inside Jev card, without displacing connections.
Shared core bottom strip "Observe · Act · Receipts".
Right service panel: "MODEL SERVICES"; "ProviderKit"; two rows "Main LLM" and "TypeSafe Jev". Bidirectional edge to core "Requests & decisions".
Lower full width band: "iOS DEVICE ADAPTER"; "Local OCR · Screenshots · Touch · Text input · App launch".
Next full width band: "CONNECTION & PROTOCOL"; two cells:
"TapitoConnectionKit", "Local VPN · Outdoor setup";
"TapitoNCM + Rust", "Pairing · Developer services · Screen & input".
Bottom band: "iPhone system and third-party apps".
Footer: "OCR runs on-device. Model requests use configured services. iOS manages background execution."

Keep all architecture paths: entry -> host -> agent core -> device adapter -> connection/protocol -> iPhone apps; knowledge linked to core; main agent directs both tools and Jev; Jev returns stage evidence to main; tools and Jev use shared underlying device operations; core emits run evidence to asynchronous learning; models connected to core. Jev does not own the whole task. Do not add an independent agent or direct Jev-to-user response. No flow-number labels. Every label and caption must be only English or the specified technical identifiers.
```

## Execution flow localization prompt

```text
Use case: text-localization.
Asset type: English GitHub README task execution diagram.
Edit target: supplied Tapito task execution image. Produce its polished ENGLISH-ONLY edition with image2. Preserve its violet/teal brand palette, warm white background, line icons, two-lane main-agent workflow, overall composition, and directed edges. Remove ALL Chinese text. Reflow and enlarge the English labels so the result is naturally typeset for English and remains easy to read at README width. Do not merely erase text leaving blanks. Landscape 3:2, 1536x1024 or greater. No watermark.

Exact labels:
Upper left brand "Tapito"; large title "Task execution".
Top card "User task"; "Request & valid context".
Below violet main card "Main Agent"; "Skills · Memory · Stage goals · Exact input".
Left branch "Direct tool calls".
Left teal lane top card "Execute device tools"; "Launch · Tap · Swipe · Type".
Arrow down into "Observe & receipts"; caption "Local OCR · Main-model vision when needed".
Right branch label "delegate_screen".
Right violet lane title "Jev collaboration"; context "Goal · Completion criteria · Exact input".
Top-right short note "Jev receives text only".
Three inner cards:
"Local OCR"
"Choose operation & target"
"Execute action".
Downward arrows OCR -> Choose -> Execute. Right side loop Execute -> Local OCR with label "Observe again".
LEFT exit originates from Choose operation & target and leads down around the action card into a separate card BELOW the Jev lane: "Return stage evidence"; caption "Done · Need input · Blocked · Budget reached". Label exit "Handoff". There must be exactly one arrowhead on this exit, pointing into Return stage evidence, never pointing into the choice card. No direct Execute-action-to-return arrow.
To the right of return card, note "Stage done does not mean task done".
Observe & receipts (left) and Return stage evidence (right) each lead into the central diamond below: "Main Agent verifies"; "Task complete?".
The diamond's NO exit loops around the outer RIGHT margin back into the Main Agent card at the TOP. Label "NO" and "Continue". Arrow points INTO Main Agent. This return loop must not intersect the stage evidence return line.
The diamond's YES exit leads vertically down to "Evidence-based answer". Label "YES".
A dashed arrow from answer leads to the bottom async learning band; label "Enqueue when enabled · Does not block reply".
Bottom dashed band: "ASYNC LEARNING", "Personal memory", "Operation candidates → Review → Later reuse".
Very bottom subtle salmon note strip: "Connection failure or uncertain delivery: stop, retain receipts, do not replay input."

Crucial: maintain all connectivity, unambiguous one-way arrows, no crossing text, no floating lines. Jev can EITHER execute and observe again OR hand back stage evidence without action. Main Agent owns the final answer; stage handoff is not task completion. Async learning does not block the answer. Keep ordinary tool flow distinct from optional delegation. No Chinese characters, no bilingual slashes, no arbitrary numbering.
```
