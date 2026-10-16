# Input and search

`type_text` writes the entire exact string through the general clipboard and Command-V. Chinese, English and emoji use the same path. It does not type letters through the on-screen keyboard. The editable target must already be focused; focusing it can still show the keyboard. No tool guarantees a hidden keyboard across apps.

Limits: nonempty text, at most 8192 UTF-8 bytes, no NUL. Existing selection determines append versus replacement. There is no select-all, replace-field or Return-key tool. Do not claim those operations happened. Clipboard contents are replaced. iOS may show paste consent; handle one prompt only for the exact user-authorized text and target, or ask the user. Never resend text merely because a prompt or response is slow.

Search example for the user's requested app and query:

1. Reuse its confirmed installed bundle ID with `launch_app`; query `list_apps` only when unknown.
2. `observe_screen` to find an unambiguous search entry in a known layout. If there are multiple "搜索" labels, only a magnifier icon, a modal overlay or uncertain editable state, inspect `screenshot(frame_id)` instead.
3. Focus the entry using the observed target. OCR input consumes those candidates. Do not use the old list again on the changed page.
4. Once focus is established, `type_text("牛肉面")` directly. A screenshot solely to make the text call is unnecessary. A visible keyboard is not a reason to tap its letters.
5. Confirm input and the submission control with a fresh observation where state is uncertain. Submit by a known visible control. Typing and submitting are separate actions.
6. Observe the result before claiming success. Do not infer matching products from text recognition alone when image or state interpretation is needed.

Known stable sequences can combine focus then text input without an intermediate model turn. Do not combine steps that depend on an unknown page. If text may already have been inserted, inspect the current state before choosing a correction; never automatically replay it.

`home` and `launch_app` need task authorization, not a screenshot. `home` does not unlock. Launch arguments are process arguments, never URLs, shell commands or guessed deep-link parameters; an already running app can ignore them.
