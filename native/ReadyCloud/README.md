# Ready: secure input and one explicit OpenAI call in one process

This purpose-bound app is separate from the prior preparation-only window. It has App Sandbox + network.client and **no file-selection/general file-read entitlement**, IPC server, HTTP relay or credential export. It accepts only the built-in bounded synthetic fixture. Existing applications and sandbox settings are unchanged.

Build and test before opening:

```sh
python3 -B native/ReadyCloud/build.py
```

The command uses only a synthetic credential and injected transport, exercises fail-closed branches and verifies a real Ed25519 audit record. It prints the new app path; it does not open a window or contact OpenAI. Open that app using the ordinary macOS launcher. After opening, agents must not inspect AX/screenshots/memory while the user may enter a credential.

## User flow

Use the window titled **VAPE · OpenAI 1회 실검증 — 준비 완료**, not the old preparation window.

1. Review the displayed recipient, pinned model and complete synthetic text.
2. Enter the API key directly into NSSecureTextField and click **1. 키 준비 — 아직 전송하지 않음**. The field is cleared/disabled and the private process-memory reference is retained. No request occurs.
3. Click **2. 위 모델·합성 내용의 OpenAI 1회 전송 승인** only when ready to approve the shown model and content. This sends exactly one application-level request; the key is never relayed to an agent or another process.
4. The native window shows the actual API outcome and response. It never executes tools. After failure/uncertain delivery the app cannot retry. Cancel discards retained key references and cancels an active task; cancellation does not imply non-delivery.

The key is not stored in files, environment, arguments, clipboard APIs, audit or Keychain. There is no credential verification API call. On execution the input-field/app key reference is cleared; the networking stack retains its in-memory request as needed until completion/cancellation. Swift/OS memory is not claimed to be cryptographically zeroed.

## Model and transport

No organization-approved model ID was found in existing source. The documented efficient model `gpt-6.1-terra` is pinned as a **demo default**, not silently represented as organization-approved. The user's explicit send button approves this one use. Source: https://developers.openai.com/api/docs/models/gpt-6.1-terra (checked during preparation). Account access, API credits and model entitlement remain unverified until the user's request.

TLS endpoint is fixed to `https://api.openai.com/v1/responses`. Standard system TLS trust/hostname verification is retained. Proxy configuration is empty, redirects are refused, credential/cookie/cache persistence disabled, and the response is capped at 1 MiB. Request: store:false, stream:false, no tools, reasoning effort none, 256 output tokens. No application retry, model fallback, file upload or arbitrary URL/body input exists. store:false is not a blanket zero-retention guarantee. The app does not change OS proxy, trust or firewall settings.

The engine first checks its fixed policy (L1 cloud deny; only explicitly approved L2 + exact model/destination/model_send allowed). It appends L1 deny and L2 intent metadata before transport. Intent persistence failure means zero calls. Result/audit failure after transport is indeterminate and preserves received/unknown status. A consumed request cannot be repeated even if the first result is uncertain. Audit metadata is Ed25519 signed and contains no document/output/key/path. This is local signed audit, not a remote-provider receipt or chain anchor.

Live execution is **not** part of the build/test step. The user must enter and explicitly click send. No agent should click that button before handoff or read credentials from the process. No system permission/profile is changed to overcome failures.

## Paste correction v2

The original source did not install an AppKit Edit menu. Version 2 adds standard responder-chain Paste (Command-V) and Select All, plus a user-clicked secure-field-only paste button. It never calls NSPasteboard directly or pastes automatically. The button first requires an editable/unprepared field and successfully focuses that secure field, then dispatches standard `paste:`. Disabled/prepared/cancelled states do not dispatch.

Use the new title **VAPE · OpenAI 1회 실검증 — 붙여넣기 수정 v2**. Tests cover menu wiring and disabled/failed-focus/successful-focus dispatch using stubs, without accessing any clipboard, screen, live key or OS key event. Actual desktop Command-V remains unverified. The existing 56 synthetic transport checks still pass. Existing windows are left untouched because their execution state is unknown; do not send again in v2 if a prior window already submitted a request.
