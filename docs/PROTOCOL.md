# Bridge Client Protocol — local-api/1

English | [中文](PROTOCOL.zh-CN.md)


<a id="scope"></a>

## 1. Scope and status

This is the public client integration reference for `local-api/1`, checked against Palmhelm Bridge 0.3.15 (bundled with Palmhelm for Mac 1.0 (156); public binary release [bridge-0.3.15](https://github.com/forsakesoul/palmhelm/releases/tag/bridge-0.3.15)) and PalmhelmKit 0.0.1. [简体中文](PROTOCOL.zh-CN.md).

**Current behavior** describes that implementation baseline. **Client rules** describe the handling needed to interoperate safely with it. Neither label promises that an optional feature exists on every Bridge, freezes implementation timing forever, or establishes an execution SLA. Bridge product versions, Kit tags and the wire protocol version are separate identifiers.

The scope is the device-facing HTTP API and SSE stream. It does not expose the engine implementation, local administration/hook ingestion interfaces, storage layout or operating credentials. All examples use synthetic values; angle-bracket placeholders must be replaced only in an authorized client session. `bridge.example.invalid` is deliberately not a real service.


<a id="transport"></a>

## 2. Addressing, TLS and identity

**Current behavior.** The conventional port is `47821`; configured endpoints may use another port. Targets and item/event identifiers are opaque. Percent-encode each identifier as one path segment; encode query values independently and do not double-encode an already encoded path.

LAN discovery uses Bonjour `_palmhelm._tcp`, with TXT `v=local-api/1`, `tls=1`, `fp=<SPKI digest>`. Discovery and advertised endpoint lists are address hints, not proof of identity. Pair/state responses may include endpoints `{host, port, transport, kind}`; `kind` may be `lan`, `tailscale` or `loopback`.

**Client rules.** Before sending a pairing code or bearer token over HTTPS, observe the actual handshake certificate's DER SubjectPublicKeyInfo, compute SHA-256 and standard base64, and compare the full digest with a trusted, user-confirmed value. This is SPKI pinning, not a hash of the whole certificate or an unchecked hostname/advertisement. The pair response's `spkiSha256` must agree with the pinned handshake; the response alone is not a trust root. A changed/missing pin is not an instruction to accept a new identity or downgrade to HTTP.

Kit's default session refuses redirects for both HTTP and HTTPS, including same-origin redirects, and uses a direct session with proxies/cache disabled. Preserve these protections when injecting a custom session. Kit on iOS rejects plaintext except literal `127.0.0.1` / `::1`; PairRoute likewise skips non-loopback HTTP. The macOS low-level client does not apply the iOS-only URL guard; this difference does not make non-loopback plaintext safe for a new client.


<a id="pair"></a>

## 3. Pairing and authentication

An operator first enables pairing on the Bridge host. `POST /pair` is the unauthenticated device endpoint. Send an object with a six-digit decimal **string** `code` (leading zeroes matter) and `deviceName`. The name is stripped of controls/trimmed and must contain 1–32 Unicode code points; unsafe names may produce `invalid_name`.

```http
POST /pair
Content-Type: application/json

{"code":"012345","deviceName":"Example phone"}
```

```json
{"deviceId":"0000000000000000","token":"<DEVICE_TOKEN>","spkiSha256":"<BASE64_SHA256_OF_SPKI>","endpoints":[{"host":"bridge.example.invalid","port":47821,"transport":"https","kind":"tailscale"}]}
```

The token has the form `<deviceId>.<secret>` and is returned by successful pairing; treat the whole value as secret. Persist it securely, separate from public diagnostics. New devices are `readonly`; an operator must grant `control` on the host. There is no device endpoint for elevating its own permission.

All supported `/v1/` endpoints, including health, require `Authorization: Bearer <DEVICE_TOKEN>`. A token in a URL query is not authentication. Invalid/revoked devices and identity-scope mismatches receive `401 {"error":"unauthorized"}`. Unknown method/path combinations may return 404 before authentication; 404 does not prove the token is valid.

Pair errors: malformed input 400, rejected/expired/absent challenge 401, oversize body 413, active lockout 429 `locked`. Currently five incorrect attempts on the challenge trigger a ten-minute lockout; do not brute force or infer exact challenge state from 401. A pairing code is single-use. A timeout/lost connection after sending can mean the device was created: stop with “result unknown”, do not retry the code or rotate addresses automatically. Probe/address failures known to precede submission can be handled separately.


<a id="conventions"></a>

## 4. JSON, permissions and failures

Use UTF-8 JSON and `Content-Type: application/json` for JSON bodies. Timestamp fields such as `t`, `createdT`, `expiresT` and `generatedT` are epoch milliseconds where present. “Units” below means UTF-16 code units unless a field explicitly says bytes/code points. Body limits count received bytes, not characters.

Routes that parse a JSON body usually allow 16 KiB, with route-specific limits listed separately: issue preview/create allow 32 KiB; hook/statusline/price-refresh bodies have a 1 KiB limit. Requests that do not read the body send an empty body or empty object. Error bodies usually contain a stable `error` string, sometimes `reason`, `state`, `status` or retry metadata. Do not display arbitrary raw server error text as trusted UI, and never log tokens, codes, submitted text or terminal text.

| HTTP | Examples | Client handling |
| --- | --- | --- |
| 400 | `bad_request`, `invalid_name`, `answer_invalid` | Correct input; do not retry unchanged input. |
| 401 | `unauthorized` | Stop authenticated operations; request recovery/re-pairing. |
| 403 | `read_only`, `input_closed`, `feishu_only` | Permission/session/channel refusal; no automatic workaround. |
| 404 | `not_found` | Missing resource or unsupported endpoint; use route context. |
| 409 | `device_paused`, `conflict`, `steer_unavailable`, `busy`, `read_only` | Inspect code; refresh the relevant facts. |
| 410 | `reset` | Discard affected transcript cursor/continuation and reload. |
| 413 | `too_large` | Reduce body bytes. |
| 429 | `busy`, `locked`, pricing rate limit | Back off; use supplied retry metadata where available. |
| 500 / 503 | `internal`, `shutting_down`, feature-specific unavailable codes | Preserve uncertainty for mutations; retry reads with backoff. |

`readonly` **device permission** rejects control operations with 403 `read_only`. A Bridge process without a write host can instead return 409 `read_only` for writes (and 404 for unavailable reads). These are different conditions. Self-management and reads do not generally require control; pause is not revocation and does not stop state/SSE/approval reads. Capabilities and UI button visibility are hints, never authorization; the server rechecks authority.


<a id="state"></a>

## 5. Health, snapshots and common wire objects

`GET /v1/health` returns `{ok, protocol, version, dispatch}`. `protocol` is `local-api/1`; `version` is the Bridge product version. `dispatch` is a feature state, not proof that any command executed.

`GET /v1/state` returns a snapshot. Core shape:

```text
BridgeState = {
  occupancy: string, targets: TargetSummary[], history: {highWater: integer, items: HistoryItem[]},
  bridge?: {id?, name?, version?, dispatch?, pushConfigured?, endpoints?, messageResponseLanguages?},
  device?: {id: string, name: string, paused: boolean, permission?: string},
  binding?: {targetId: string, projectName: string, agentName?: string}, hold?: string,
  inflight?: {eventKey: string, state: string}[], commands?: ApiCommand[], commandsTruncated?: boolean,
  pendingApprovals?: integer, approvals?: ApprovalView[], spaces?: SpaceInfo[],
  currentBlocked?: {targetId, eventKey, blockedSince}[], currentBlockedFresh?: boolean, observation?: {t: integer, complete: boolean, fresh?: boolean}
}
HistoryItem = {seq: integer, uuid: string, text: string, kind: string, replyTo?: string, target?: object, t?: integer, displayMessage?: object, displaySpans?: object[]}
ApiCommand = {key: string, inboxSeq: integer, text: string, truncated: boolean, origin: string, state: string,
  device?: {id, name}, targetId?: string, reason?: string, lane?: string, createdT?: integer,
  queueDeadlineT?: integer, mode?: string, directAgent?: string,
  queueReason?: string|null, queuePosition?: integer|null, observedAt?: integer|null, phase?: string|null,
  stopDisposition?: string|null}
```

`?` denotes optional/nullable wire data, not a Swift computed property. Field shapes (required and optional keys) are defined in [Models.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/Models.swift) and the schema catalog in section 17. Use targetId when supplied; names are display data. Location/capabilities can change. State history/commands are bounded current windows (currently up to 200), not a complete audit export.

Read `currentBlocked` only together with `currentBlockedFresh`; missing/stale evidence or absent `observation` is not proof that a target is absent or no longer blocked. `commandsTruncated` is snapshot-scope information. Queue metadata is **flat on the wire**, not a nested `queue` object: missing all four keys means an old payload; explicit null clears the applicable value. Unknown/null `stopDisposition` is uncertain; only `not_dispatched` proves the server's reported non-dispatch classification. `execution_uncertain` must not be shown as “never executed”.

Display extensions are suggestions, never authority: `displayMessage:{key,params}` localizes known semantic signatures and falls back to canonical text on invalid/unknown data; `displaySpans:[{startUTF16,endUTF16,key}]` marks half-open UTF-16 ranges in the corresponding canonical text. Accept only recognized, in-bounds, non-overlapping spans whose source text matches the canonical atom; otherwise preserve raw text. Do not globally replace user words that resemble a generated placeholder. Search ranges refer to canonical snippet text; localization requires offset mapping.


<a id="sse"></a>

## 6. SSE subscription and recovery

Open `GET /v1/events?since=<last-outbox-seq>` with bearer authentication and `Accept: text/event-stream`. `since` is an optional non-negative decimal integer (currently 1–15 digits); this endpoint uses the query cursor, not a presumed `Last-Event-ID` implementation. One active SSE connection is kept per device: a new connection replaces the old one.

Frames end with a blank line. `event` names the payload; `data` is JSON. Only `outbox` has a durable `id`/history sequence. Normal synchronization is `sync`, initial `targets` when available, ascending outbox history, then `ready`, followed by live events. Do not treat non-outbox events as a separately durable replay log.

| Event | JSON data |
| --- | --- |
| `sync` | `{highWater: integer, count: integer, mode: "snapshot"|"backfill"}` |
| `outbox` | `HistoryItem`; frame `id` is its `seq` |
| `ready` | `{highWater: integer}` |
| `targets` | `{targets: TargetSummary[], spaces?, currentBlocked?, currentBlockedFresh?, observation?}`; full target snapshot |
| `inbound` | `ApiCommand` |
| `progress` | `{eventKey, state, reason?, queueReason?, queuePosition?, observedAt?, phase?, stopDisposition?}` |
| `approval` | `ApprovalView` summary |
| `device` | `{id, name, paused, permission?}` for this device |
| `transcript_changed` | `{targetId, sessionEpoch, revision, kind}`; kind currently `session`, `reset`, `append` |
| `reset_required` | `{highWater: integer}`; stream ends |
| `ping` | `{}`; current heartbeat interval 25s |

```text
event: sync
data: {"highWater":42,"count":1,"mode":"backfill"}

id: 42
event: outbox
data: {"seq":42,"uuid":"synthetic-receipt","text":"Example result","kind":"reply","t":1700000000000}

event: ready
data: {"highWater":42}

```

Without since, the current snapshot contains up to the latest 200 history items. A cursor within `[highWater-500, highWater]` can backfill visible outbox history; outside that range the server sends reset_required and closes. Slow/disconnected/revoked streams can close too. Deduplicate by stable sequence/identity and advance the resume cursor only after accepting a valid outbox item. Reload `/v1/state` and pending approvals when recovering; on reset_required discard the stale replay assumption and resynchronize. Progress/approval/device facts require snapshot recovery, not just outbox backfill.

`transcript_changed` contains **no body**. Fetch the relevant transcript separately; `reset`/`session` invalidates old paging assumptions. It is not a token-delta stream. Unknown event names (and currently known events that Kit cannot decode) become `.unknown`; do not advance an outbox cursor for them. A client can reconnect with bounded exponential backoff; Kit's helper starts at 1s, caps at 30s and applies up to ±20% jitter. BridgeClient's stream is one attempt; it does not itself implement the entire recovery loop.


<a id="messages"></a>

## 7. Messages and queue actions

These operations require control. `POST /v1/messages` accepts `clientMsgId` (UUID), non-empty `text` (at most 8000 units), optional `mode` (`queue`, `steer`, `send_now`), optional `queueTTLSeconds` (3600 or 86400), optional `responseLanguage`. Explicit mode fixes the send intention; omitted mode retains legacy text-based routing. Prefer an explicit supported mode for new UI. `steer` is a supplemental insertion attempt; `send_now` may start another turn. Capability flags are advisory and refusal is possible after selection.

```json
{"clientMsgId":"00000000-0000-4000-8000-000000000001","text":"Example request","mode":"queue"}
```

Successful send is `{received:true,eventKey:string}`. That is receipt/acceptance, **not completion or guaranteed execution**. Track the same eventKey in state, progress and receipts. `unknown` is not terminal proof of failure and can later converge. A `merged` reason means acknowledged merging, not that the agent followed the instruction. `responseLanguage` controls fixed synchronous reports, not arbitrary agent content; the baseline supports `zh`/`en`, with omitted/null/unknown strings using zh. Use the advertised language capability on older Bridges.

`POST /v1/messages/{eventKey}/promote` accepts `{mode:"steer"|"send_now"}` and returns `{eventKey,mode,state:"queued"}` on success. It conditionally changes the existing queued message; never implement it as delete-and-resend. `DELETE /v1/messages/{eventKey}` returns `{withdrawn:true,eventKey}` if it can stop future dispatch. `not_withdrawable`, `not_promotable`, `conflict` or `steer_unavailable` are refusals, not invitations to create another message. Withdraw is cleanup and is not blocked by the device pause that blocks send/promote.

Retain the original clientMsgId/eventKey while reconciling a send. Do not generate a fresh UUID or replay a non-idempotent action automatically after timeout, invalid success data or 5xx. No blanket exactly-once execution guarantee is made. In Kit 0.0.1, send/promote/withdraw success decoders require the **exact key sets shown above**, and promote/withdraw verify intent/identity; adding response fields is not automatically backward-compatible for these paths.


<a id="approvals"></a>

## 8. Approvals, questions and plans

Reads are available to paired readonly devices. `GET /v1/approvals?status=pending` returns `{approvals: ApprovalView[]}`. `GET /v1/approvals/{id}` returns `{approval:{view:ApprovalView,body?,reviseCount?,cause?}}`; ids currently contain 16 lowercase hexadecimal characters.

ApprovalView requires `{id,status,targetLabel,toolName,summary,truncated,createdT,expiresT}` and can include targetId, attribution, decidedBy, provider, kind, questionCount, reviseCount, hint, options, optionsVaried, messageSupported and display metadata. Options are `{id,kind,label,detail?,enabled,disabledReason?}`. Bodies/cause belong to the detail endpoint, not the SSE/list summary. Missing cause/body is not an empty original tool input. All returned content is a display projection.

Control decisions use `POST /v1/approvals/{id}`:

| Kind | Body | Notes |
| --- | --- | --- |
| Ordinary approval | `{decision:"allow_once"}` or `{decision:"deny",message?:string}` | No “always allow”; message is only valid for deny, max 500 units. |
| Question | `{decision:"answer",answers:[...]}` | One entry per question, no omissions/duplicates/out-of-range choices. |
| Plan | `{decision:"revise",message?:string}` (legacy deny also revises) | Max 500 units; API approval of plans is unsupported. |
| Question / plan | `{decision:"release"}` | Return control to the terminal. |

Each answer is encoded as `{question:integer,option:[integer,...]}` or `{question:integer,text:string}` with an explicit zero-based question index (option indexes are also zero-based); free text is at most 500 units; use the choices/selectability/multiSelect rules from detail. Question body fields include header, question, multiSelect and options `{label,description,preview?,selectable}`; plan body can include plan text; change detail can include projected path/kind/hunks. Do not infer a hidden choice from placeholder text.

Success returns `{status}` with optional projected message/messageProjected, reviseCount, hint. Display the returned projected message rather than assuming the input survived unchanged. On 409 conflict the approval may already be decided/expired/withdrawn; refresh, do not auto-submit another decision. Errors include answer_invalid, wrong_kind, use_answer and plan_approve_unsupported.


<a id="transcript"></a>

## 9. Transcript pages, conditional reads and receipts

`GET /v1/targets/{targetId}/transcript?limit=20&before=<cursor>` is a readonly display interface. limit is 1–20, default 20. Omit before for the latest page; pass nextBefore unchanged for older pages. Each page is ordered oldest to newest. Treat sessionEpoch, revision, item id and cursors as opaque.

```text
TranscriptPage = {status: string, sessionEpoch?: string, revision?: string,
  items: TranscriptItem[], nextBefore?: string, hasMore: boolean, partial: boolean,
  reason?: string, receiptUpdates?: {itemId: string, receipt: TranscriptReceipt}[]}
TranscriptItem = {id: string, role: string, text: string, t?: integer, truncated: boolean,
  projected?: boolean, receipt?: TranscriptReceipt, reason?: string, continuation?: string,
  displaySpans?: object[], displayMessage?: object}
TranscriptReceipt = {commandKey: string, origin: string, receiptState: string, reason?: string, eventKey?: string}
```

`status:"unavailable"` is not an empty conversation; retain/fallback to the appropriate receipt history. `partial:true` can contain no items but a forward-moving cursor; an empty page is not end-of-history. Stop on hasMore=false; avoid a hot retry loop if a partial cursor makes no progress. A stale cursor/continuation can return 410 reset, including after a server restart; discard it and reload the latest page. Target disappearance can return 404.

Only projected user/assistant display text and gap rows are exposed, not raw tool/thinking/system payloads. Do not reconstruct redacted content or perform client-side text/time guessing to associate a receipt. `receiptState` currently includes accepted/sent/done/unknown; eventKey, when supplied, permits exact local-send association. Other devices' messages need not expose your eventKey.

A 200 page can carry ETag. Send If-None-Match only while retaining the same cached page and request shape (endpoint/device/target/before/limit and receipt declarations). 304 has no page body and means retain that cache; it is not an empty page or revoked authorization. Do not reuse validators across identity/scope/request changes or assume they survive restart.

For latest-page receipt backfill, send one receiptEpoch and repeated receiptEventKey query fields (at most 20 receiptEventKey fields, normalized to distinct keys; each value nonempty, valid UTF-8, control-free and at most 256 UTF-8 bytes; encoded declaration budget 16 KiB). Do not combine these with before. Normalize consistently. receiptUpdates can patch already-loaded user items only for the same epoch/snapshot and a declared eventKey; reject duplicate item ids/conflicts, do not create unknown rows or match by text. Missing/empty updates means no patch.


<a id="continuation"></a>

## 10. Continuation, ledger history and search

`GET /v1/targets/{targetId}/transcript/items/{itemId}?cont=<continuation>` reads another segment of a truncated item. Use only server-issued tokens, bound to the corresponding item/session; never invent offsets. Response: `{status,sessionEpoch?,itemId?,text?,hasMore?,continuation?,reason?,displaySpans?}`. Merge only matching identities in the requested order. A missing continuation on a truncated item is not permission to fetch an arbitrary file.

`GET /v1/targets/{targetId}/history?before=<cursor>&limit=20` reads that target's message/receipt ledger, including archived targets. limit defaults to 20, maximum 50. Response `{items,nextBefore?,hasMore,partial}`; items are oldest to newest within a page, pages go toward older history. Rows have `{id,source,text,t?,kind?,replyTo?,targetId?,state?,...}`. Inbox rows may carry ApiCommand fields **at the same level**, not inside a `command` wire object. Cursors remain opaque; they are positions, not authorization. Partial empty pages need not mean no history.

`GET /v1/search?q=<text>&limit=<n>` searches projected conversation text. Trimmed q must be 2–128 units; limit 1–50, server default 20 (Kit normally asks for 30). Response `{results,partial,scanned:{targets,pages},skipped:[{targetId,reason}]}`. Each hit is `{targetId,itemId,sessionEpoch,pageBefore?,role,t?,snippet,ranges,snippetDisplaySpans?}`; ranges are `[start,length]` in snippet UTF-16 units. Search identity is targetId+itemId, not itemId alone. Use pageBefore to load the containing transcript page; omitted means latest. No result pagination or exhaustive-all-history guarantee is provided. Partial plus no results is not “no matches”; concurrent searches can be refused with 409 busy.


<a id="terminal"></a>

## 11. Terminal display and explicit input

`GET /v1/targets/{id}/screen` is readonly. Response `{status,revision?,t?,cols?,rows?,lines?,truncated?,hidden?}`. Unavailable is not a blank terminal; hidden content must remain hidden. This is a projected viewport, not raw scrollback or an input channel. Kit's current foreground polling recommendation is 2s, not a server delivery SLA.

`POST /v1/targets/{id}/reveal` with `{}` requires control and focuses the target on the host. It does not open an input session.

Input endpoints:

| Method/path suffix | Request | Success / authority |
| --- | --- | --- |
| GET `/input/session` | none | `{open:false}` or `{open:true,expiresT}`; readonly may inspect |
| POST `/input/session` | `{}` | `{expiresT}`; control, explicit open/renew, current lifetime10min |
| DELETE `/input/session` | `{}` | `{}`; control, close (also if already closed) |
| POST `/keys` | `{keys:[...]}` **or** `{text:string}` | `{sent:integer}`; control plus a live input session |

Keys: 1–8 names from enter, esc, tab, up, down, left, right, backspace, ctrl+c, ctrl+d, space. Text is one line, at most 200 units, no CR/LF, and does **not** automatically press Enter. Do not combine keys and text. Input may fail with input_closed, approval_pending, pane_changed, read_only or busy. Closing invalidates in-flight opens/renewals; restarting the Bridge closes the in-memory session. Authority and target identity are rechecked. Lost responses to keys/text are execution-uncertain: never replay automatically.


<a id="self"></a>

## 12. Device self-management and APNs registration

All routes are authenticated and act on the current device; they do not grant permission.

| Route | Request | Success |
| --- | --- | --- |
| PATCH `/v1/devices/self` | `{name:string}` | `{device:{id,name,paused,permission?}}` |
| PUT `/v1/devices/self` | `{paused:boolean}` | same device envelope |
| DELETE `/v1/devices/self` | `{}` | `{removed:true}`; token stops authenticating, stream closes |
| PUT `/v1/devices/self/push` | `{token:string,environment:"development"|"production",localizationVersion?:integer}` | `{registered:true}` |
| DELETE `/v1/devices/self/push` | no registration secret | `{removed:true}` |

APNs token is 64 hexadecimal characters (Kit accepts lowercase; server normalizes case). This token is distinct from the device bearer token. localizationVersion=1 declares support for localized push keys; omit it for the legacy payload behavior. Registration success is not delivery confirmation. Push availability depends on the Bridge configuration; a push notification is a prompt to refresh authenticated state, not authority to decide an approval or resend an unknown command.


<a id="issue"></a>

## 13. Issue-task preview and confirmation

These are optional endpoints. A 404 from the **options endpoint** indicates unsupported for Kit; a 404 for a specific issue is not the same signal.

| Route | Shape |
| --- | --- |
| GET `/v1/issue-tasks/options` | `{createSupported,dispatchEnabled,github:{available,reason?,createSupported},sources:[{sourceId,repo}],targets:[{targetId,label,destinationVersion?,reason?,labelPlaceholder?}],maxPromptUnits,templateLanguages?}` |
| GET `/v1/issue-tasks/github/issues?sourceId=...&page=1` | `{items:[{number,title,state,updatedAt,url,titlePlaceholder?}],page}` |
| GET `/v1/issue-tasks/github/issues/{sourceId}/{number}` | `{number,title,state,updatedAt,url,body,sourceVersion,titlePlaceholder?,bodyPlaceholder?}` |
| POST `/v1/issue-tasks/preview` | control; request below; returns `{text,textDigest,destinationVersion,sourceVersion?}` |
| POST `/v1/issue-tasks` | control; same request plus clientMsgId/textDigest;202 `{accepted,eventKey}` |

Preview request: `{targetId,destinationVersion,source,instructions?,ackClosed?,templateLanguage?}`. Source is `{kind:"github",sourceId,number,version}` or `{kind:"manual",title,description?,referenceUrl?}`. Source/destination versions are opaque. Copy versions and digest from fresh options/detail/preview, not from display names. Manual title must be nonempty, single-line, at most 200 units; use maxPromptUnits for the complete server-built prompt. A reference URL is restricted to a canonical HTTPS GitHub issue URL. Source placeholders are display-only, not deployable content.

Preview is not submission. The server constructs the authoritative text; confirmation sends its digest, not client-edited text. Confirmation requires a UUID clientMsgId; textDigest is 64 lowercase hex characters. Preview and confirmation must use the same source, instructions, language and intended destination. The request allowlists reject unknown keys. On source_changed refresh detail; on destination_changed refresh options; on preview_changed preview again. A changed preview needs renewed user confirmation. `ackClosed` is the explicit closed-issue acknowledgement.202 means queued, not executed.

templateLanguage supports zh/en when advertised; it translates the fixed envelope, not the source issue/body/instructions. Absent/null/unknown strings currently select zh. An uncertain create response is not a failed create: preserve identity and do not createOnce twice automatically. Idempotent replay has identity checks and can return idempotency_conflict; it is not a license to change source/body under the same identifier.


<a id="optional"></a>

## 14. Optional device extensions (accounts, usage, host integration)

These routes may be unavailable on an older or differently configured Bridge; handle 404/feature errors separately from a valid empty snapshot.

| Route | Request / response | Authority |
| --- | --- | --- |
| GET `/v1/accounts` | optional refresh=1; `{accounts:[AccountSnapshot],throttled?,claudeExperimental?}` | read |
| GET `/v1/usage` | window=5h/24h/7d/30d; `UsageResponse` | read |
| POST `/v1/usage/prices/refresh` | no application input; `{result:"updated"|"current",pricing:UsagePricingInfo}` or error/retry metadata | control |
| GET `/v1/hooks/{claude|codex}` | `{installed,trust,stale?,lastFailure?,managedLocation?,configVersion?}` | read |
| POST `/v1/hooks/{claude|codex}` | `{action:"install"|"uninstall",expectedConfigVersion?:string}`; `{ok,error?}` | control |
| GET `/v1/accounts/claude/statusline` | `{installed:boolean}` | read |
| POST `/v1/accounts/claude/statusline` | `{action:"install"|"uninstall"}`; optional ok/settings/restored/warnings/error fields | control |

Field shapes: [QuotaAccounts.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/QuotaAccounts.swift). Missing usedPercent after reset is not 0% usage; stale/error/awaiting_refresh is not a fresh balance. refresh=1 is currently throttled to 60s and can return cached data with throttled=true.

Account `planQuota` (optional, Qoder only): `"not_included"` means the plan credit total is confirmed as 0; show "Your plan doesn't include plan credits". Missing or unknown values show nothing, per `CONTRIBUTING.md` compatibility rules.

Field shapes: [Usage.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/Usage.swift). Coverage is evidence of indexing progress, not a guarantee of completeness. Estimate is explicitly versioned: decode known version 1 only; unknown versions must not invalidate the rest of the response. Null/unpriced/partial/stale cost is not a verified zero or a billing invoice. Use the versioned estimate/provenance rather than inventing a total from incomplete legacy prices.

Hook install/uninstall changes host configuration and requires explicit user intent. managedLocation/configVersion support ownership checks: do not silently overwrite another installation; a confirmation/version conflict requires refreshed status and an explicit confirmed action. Unreadable status is not “not installed”. Do not display raw host paths/failure contents as trusted instructions. The full optional measurement/detail field definitions are linked in the public schema catalog below.


<a id="deadlines"></a>

## 15. Deadlines, uncertainty and retries

Kit's defaults are client policy, not a server completion guarantee:

| Operation | Current deadline |
| --- | --- |
| Ordinary request / TLS probe |10s absolute |
| Pair POST |15s absolute |
| SSE response headers / first-byte attempt |15s absolute |
| SSE transport idle fallback |90s idle (not an absolute stream lifetime) |
| Multi-address refresh round helper |20s |

A caller-supplied BridgeClient timeout overrides the ordinary/per-operation data deadline. Request timeoutInterval alone is an idle timeout and does not bound a continuously trickling body; enforce an absolute deadline and cancellation. A stream needs recovery/liveness handling after headers, not an absolute10s lifetime. Timings/polling can evolve independently of local-api/1.

Classify outcomes as: confirmed success, explicit refusal, or unknown. Do not turn timeout/network loss/malformed success into “not sent”. Read recovery can retry with bounded backoff and identity checks. Writes need operation-specific reconciliation: inspect state/receipts using original identifiers, refresh conflicting resources, and ask for a fresh explicit action where appropriate. Never automatically resend terminal input or a consumed pairing code. Retrying a write on another address can duplicate effects even when both addresses belong to the same Bridge.


<a id="compat"></a>

## 16. Compatibility, upgrades and rollback

**Current compatibility behavior.** Most snapshot DTOs ignore unknown object keys, expose many status/reason values as strings and make extensions optional. This is not a promise that every wrong type or every unknown enum decodes: transport and some typed enums can fail; known malformed SSE frames become unknown; specialized success decoders can be strict. Do not blanket-enable a new write feature from a version number or a missing field.

Keep these distinctions: missing optional capability versus false; missing queue group versus explicit null; unknown status versus finished; unavailable/partial versus empty; unknown execution versus never dispatched. Kit preserves a legacy absent-permission fallback for old Bridges, but server authorization remains decisive; a new client should not infer an elevation from unrecognized data.

Discover support from the endpoint/capability actually used. Old endpoint 404 can disable that optional feature; resource 404 must not disable the whole protocol. Check protocol before connecting operational UI. Do not send secrets to an unconfirmed replacement identity. Product upgrades should preserve stored Bridge identity, pin, device association and opaque cursors only where still valid; reset and re-pair when required by changed identity/authorization rather than silently migrating authority.

Kit tags are immutable; fixes use a new tag and consumers pin the chosen version. A rollback can remove optional endpoints/fields or invalidate paging/session state: retain drafts, cancel obsolete in-flight work, refresh snapshots and keep unsupported controls unavailable. Neither this document nor the public Kit grants permission to publish the engine, change host configuration, rotate secrets or perform an automatic downgrade. Compatibility promises beyond this checked baseline require an explicit reviewed protocol decision.


<a id="schemas"></a>

## 17. Public schema catalog

The compact wire shapes above describe the integration contract. These fixed-tag public definitions supply the detailed nested/optional fields and decoding exceptions; they are part of this reference, require no private repository access, and must be read as wire DTOs rather than every Swift computed property. This is a source-backed schema catalog, not a machine-readable JSON Schema or a claim that all fields are required.

| Public source | Coverage |
| --- | --- |
| [Models.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/Models.swift) | Health/state/targets/devices/history/approvals/transcript/search/screen/input wire DTOs |
| [ThreadArchive.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/ThreadArchive.swift) | Observation DTO and conservative evidence consumption |
| [Constants.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/Constants.swift) | Protocol, paths, units, limits and event/status names |
| [SSEParser.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/SSEParser.swift) | Frame splitting and event payload decoding |
| [MessageActions.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/MessageActions.swift) | Send/queue intents and strict success/error decoding |
| [QueueStatus.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/QueueStatus.swift) | Flat queue keys and stopDisposition decoding |
| [TranscriptSync.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/TranscriptSync.swift) | Continuation segments, ETag result handling and paging helpers |
| [TranscriptReceiptBackfill.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/TranscriptReceiptBackfill.swift) | Receipt declarations and safe patch acceptance |
| [TargetHistory.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/TargetHistory.swift) | Ledger row/page shapes; flat inbox command fields |
| [IssueTasks.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/IssueTasks.swift) | Issue options/list/detail/preview/create request and response definitions |
| [Usage.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/Usage.swift) | Usage and estimate version 1 nested measurement/provenance fields |
| [QuotaAccounts.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/QuotaAccounts.swift) | Quota account/window and statusline field definitions |
| [HookInstallation.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/HookInstallation.swift) | Installation status/ownership/result definitions |
| [BridgeDisplayMessage.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/BridgeDisplayMessage.swift) | Semantic display-message extension |
| [BridgeDisplayText.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/BridgeDisplayText.swift) | Lossy display spans and safe localization projection |
| [BridgeClient.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/BridgeClient.swift) | Client requests, transport setup and deadline application |
| [PairRoute.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/PairRoute.swift) | Pairing confirmation and unknown-result handling |
| [Pinning.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/Pinning.swift) | SPKI format, certificate pin comparison and redirect refusal |
| [ReconnectPolicy.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/ReconnectPolicy.swift) | Bounded client reconnection helper |
