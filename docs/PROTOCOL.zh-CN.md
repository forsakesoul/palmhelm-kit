# Bridge 客户端协议 — local-api/1

[English](PROTOCOL.md) | 中文


<a id="scope"></a>

## 1. 范围与状态

本文是 `local-api/1` 的公开客户端对接入口，核对基线为 Palmhelm Bridge 0.3.15（随 Palmhelm for Mac 1.0 (156) 捆绑；公开二进制发布 [bridge-0.3.15](https://github.com/forsakesoul/palmhelm/releases/tag/bridge-0.3.15)）与 PalmhelmKit 0.0.1。[English](PROTOCOL.md)。

**当前行为**描述该实现基线；**客户端规则**描述与之安全对接所需的处理方式。这些标记不代表每个 Bridge 都提供可选功能，不永久固定实现时序，也不构成执行时限承诺。Bridge 产品版本、Kit tag 与线协议版本是不同标识。

范围仅为面向设备的 HTTP API 和 SSE，不公开引擎实现、本机管理/钩子上报接口、存储布局或运营凭据。示例均为合成值；尖括号占位值只能在已授权的客户端会话中替换。`bridge.example.invalid` 故意使用不可用的示例域名。


<a id="transport"></a>

## 2. 地址、TLS 与身份

**当前行为。** 约定端口为 `47821`，配置后的端点可使用其他端口。target、item、event 等标识是不透明值；每个标识独立编码为一个路径段，查询值独立编码，不重复编码已编码的路径。

局域网发现使用 Bonjour `_palmhelm._tcp`，TXT 包含 `v=local-api/1`、`tls=1`、`fp=<SPKI摘要>`。发现结果与自报地址表只是地址提示，不证明身份。配对/state 可带端点 `{host, port, transport, kind}`；kind 可为 `lan`、`tailscale`、`loopback`。

**客户端规则。** 在 HTTPS 上发送配对码或 Bearer 前，读取实际握手证书的 DER SubjectPublicKeyInfo，计算 SHA-256 后用标准 base64 编码，与可信且经用户确认的完整摘要核对。这是 SPKI 固定，不是整张证书摘要，也不是直接信任主机名/广播。配对响应的 `spkiSha256` 必须与已固定握手一致；响应本身不是信任根。pin 改变或缺失不代表可以接受新身份或降级 HTTP。

Kit 默认会话拒绝 HTTP/HTTPS 的全部重定向，包括同源重定向，并使用关闭代理/缓存的直连会话。注入自定义 session 时须保留这些防线。Kit 在 iOS 上只允许字面量 `127.0.0.1` / `::1` 使用明文，PairRoute 也跳过其他 HTTP 地址。macOS 底层客户端没有这个 iOS 专属 URL 拦截；不能据此认为新客户端使用非回环明文是安全的。


<a id="pair"></a>

## 3. 配对与鉴权

先由操作者在 Bridge 主机启用配对。`POST /pair` 是设备侧不带鉴权的入口。请求对象包含六位十进制**字符串** `code`（前导零不能丢）和 `deviceName`。名字去控制字符并去首尾空白后须为 1–32 个 Unicode 码点；不安全的名字可能返回 `invalid_name`。

```http
POST /pair
Content-Type: application/json

{"code":"012345","deviceName":"Example phone"}
```

```json
{"deviceId":"0000000000000000","token":"<DEVICE_TOKEN>","spkiSha256":"<BASE64_SHA256_OF_SPKI>","endpoints":[{"host":"bridge.example.invalid","port":47821,"transport":"https","kind":"tailscale"}]}
```

成功配对返回 `<deviceId>.<secret>` 形式的令牌，整体都属于秘密，应安全持久化且不进入公开诊断。新设备默认 `readonly`，须由主机操作者授予 `control`。设备不能通过任何设备接口提升自身权限。

所有已支持的 `/v1/` 接口（包括 health）均须携带 `Authorization: Bearer <DEVICE_TOKEN>`。查询串中的 token 不构成鉴权。设备无效/撤销或身份范围不符统一返回 `401 {"error":"unauthorized"}`。未知方法/路径可能先返回404，不能据此证明令牌有效。

配对错误：形状错误400，挑战不存在/失效/不正确401，请求体超限413，锁定中429 `locked`。当前一个挑战累计五次错码会锁定十分钟；不要暴力尝试，也不要从401猜挑战细节。配对码只能消费一次。发送后超时/断线可能意味着已创建设备：显示“结果未知”，不自动重试该码或换地址重发。能够确认发生在提交前的探测/连通失败可以单独处理。


<a id="conventions"></a>

## 4. JSON、权限与错误

正文使用 UTF-8 JSON，JSON 请求带 `Content-Type: application/json`。出现时，`t`、`createdT`、`expiresT`、`generatedT` 等时间为 epoch 毫秒。下文“单位”默认指 UTF-16 码元，明确标注字节/码点者除外。请求体限制按实际接收字节计，不按字符数计。

解析 JSON 正文的接口通常上限16 KiB，特定路由另列：Issue预览/创建32 KiB；钩子/状态行/价格刷新请求体1 KiB。不读正文的请求发送空正文或空对象。错误通常含固定字符串 `error`，有时附带 `reason`、`state`、`status` 或重试元数据。不要将任意服务端错误原文当可信UI展示，也不要记录令牌、配对码、发送正文或终端文本。

| HTTP | 示例 | 客户端处理 |
| --- | --- | --- |
| 400 | `bad_request`、`invalid_name`、`answer_invalid` | 修正输入，不原样重试。 |
| 401 | `unauthorized` | 停止鉴权操作，进入恢复/重新配对。 |
| 403 | `read_only`、`input_closed`、`feishu_only` | 权限/会话/通道拒绝，不自动绕过。 |
| 404 | `not_found` | 资源不存在或端点不支持，结合路由判断。 |
| 409 | `device_paused`、`conflict`、`steer_unavailable`、`busy`、`read_only` | 根据错误码刷新相关事实。 |
| 410 | `reset` | 丢弃受影响的会话游标/续读令牌并重拉。 |
| 413 | `too_large` | 减少请求体字节。 |
| 429 | `busy`、`locked`、价格限流 | 退避，有重试元数据时按其处理。 |
| 500 / 503 | `internal`、`shutting_down`、功能不可用码 | 写操作保留结果不确定性；读取可退避重试。 |

设备权限为 `readonly` 时，控制操作返回403 `read_only`。Bridge进程没有写宿主时，写请求可返回409 `read_only`，不可用读取可返回404。这是两种情况。自管理和读取一般不要求control；暂停不等于撤销，不停止state/SSE/审批读取。capabilities和按钮可见性只是提示，不是授权，服务端仍会复核。


<a id="state"></a>

## 5. 健康检查、快照与公共对象

`GET /v1/health` 返回 `{ok, protocol, version, dispatch}`。protocol为 `local-api/1`，version为Bridge产品版本。dispatch是功能状态，不能证明某条指令已执行。

`GET /v1/state` 返回快照，核心形状如下：

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

`?`表示可选/可空的线数据，不表示Swift计算属性。字段形状（各对象的必需键与可选键）见 [Models.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/Models.swift) 与第 17 节公开 schema 目录。存在targetId时使用它，名字只是展示数据；位置与能力可能改变。state中的history/commands是有界当前窗口（当前最多200条），不是完整审计导出。

currentBlocked必须结合currentBlockedFresh读取；证据缺失/陈旧或没有observation，不证明目标不存在或已解除阻塞。commandsTruncated描述快照范围。队列元数据在线上是**平铺字段**，不是嵌套queue；四键全缺表示旧载荷，显式null清除对应值。stopDisposition未知/null均按不确定；只有not_dispatched表达服务端报告的未派发分类，execution_uncertain不能显示为“从未执行”。

显示扩展只是建议，不构成权限：`displayMessage:{key,params}`按已知语义签名本地化，非法/未知时回退canonical原文；`displaySpans:[{startUTF16,endUTF16,key}]`标注对应canonical正文的UTF-16半开区间。只接受已知、界内、不重叠且源文等于规范原子的范围，否则保留原文。不要全局替换长得像生成占位的用户文字。搜索ranges相对canonical snippet，本地化后须映射偏移。


<a id="sse"></a>

## 6. SSE 订阅与恢复

通过 `GET /v1/events?since=<最后的outbox序号>` 订阅，带Bearer和 `Accept: text/event-stream`。since是可选非负十进制整数（当前1–15位数字）；此接口使用查询游标，不能假设它实现了Last-Event-ID。每设备只保留一条SSE，新连接替换旧连接。

帧由空行结束；event标识载荷，data为JSON。只有outbox带持久历史序号id。正常同步为sync、可用时的初始targets、按序号递增的outbox历史、ready，随后实时事件。其他事件不是独立的持久可重放日志。

| 事件 | JSON data |
| --- | --- |
| `sync` | `{highWater: integer, count: integer, mode: "snapshot"|"backfill"}` |
| `outbox` | `HistoryItem`，帧id等于seq |
| `ready` | `{highWater: integer}` |
| `targets` | `{targets: TargetSummary[], spaces?, currentBlocked?, currentBlockedFresh?, observation?}`，完整目标快照 |
| `inbound` | `ApiCommand` |
| `progress` | `{eventKey, state, reason?, queueReason?, queuePosition?, observedAt?, phase?, stopDisposition?}` |
| `approval` | `ApprovalView`摘要 |
| `device` | 本设备的`{id, name, paused, permission?}` |
| `transcript_changed` | `{targetId, sessionEpoch, revision, kind}`，当前kind为session/reset/append |
| `reset_required` | `{highWater: integer}`，随后结束流 |
| `ping` | `{}`，当前心跳间隔25秒 |

```text
event: sync
data: {"highWater":42,"count":1,"mode":"backfill"}

id: 42
event: outbox
data: {"seq":42,"uuid":"synthetic-receipt","text":"Example result","kind":"reply","t":1700000000000}

event: ready
data: {"highWater":42}

```

不传since时，当前快照最多包含最近200条历史。游标在[highWater-500, highWater]内可补发可见outbox，越界则reset_required并关闭。慢连接、断网、撤销也可能断流。用稳定序号/身份去重，仅在接纳有效outbox后推进续传游标。恢复时重拉state和待批审批；遇到reset_required，放弃旧续传假设并重新同步。progress/approval/device事实需要快照恢复，不能只依赖outbox补发。

transcript_changed**不含正文**，须另拉相关会话；reset/session使旧分页假设失效。它不提供token增量。未知事件名，以及Kit当前无法解码的已知事件，均转为unknown，不据其推进outbox游标。客户端可有界指数退避重连；Kit辅助规则从1秒起、封顶30秒，抖动最多±20%。BridgeClient提供的是单次流尝试，本身不实现完整恢复循环。


<a id="messages"></a>

## 7. 发送与队列操作

这些操作要求control。`POST /v1/messages` 接受clientMsgId（UUID）、非空text（最多8000码元）、可选mode（queue/steer/send_now）、可选queueTTLSeconds（3600或86400）和responseLanguage。显式mode固定发送意图，省略时保留旧文本路由。新UI优先显式选择已支持mode。steer尝试补充插入，send_now可能另起一轮。能力标记仅作提示，选择后仍可能被拒绝。

```json
{"clientMsgId":"00000000-0000-4000-8000-000000000001","text":"Example request","mode":"queue"}
```

成功发送返回 `{received:true,eventKey:string}`，这表示收到/受理，**不表示完成或保证执行**。用同一个eventKey跟踪state、progress与回执。unknown不证明失败已终结，之后仍可能收敛。merged表示已确认并入，不证明agent采纳。responseLanguage只控制固定同步报告，不翻译任意agent正文；基线支持zh/en，缺省/null/未知字符串按zh处理。对旧Bridge应检查已声明的语言能力。

`POST /v1/messages/{eventKey}/promote` 接受 `{mode:"steer"|"send_now"}`，成功返回 `{eventKey,mode,state:"queued"}`。它对既有排队消息做条件转换，不应先删再发。`DELETE /v1/messages/{eventKey}` 在可停止未来派发时返回 `{withdrawn:true,eventKey}`。not_withdrawable、not_promotable、conflict、steer_unavailable是拒绝，不表示可以另造一条消息。撤回是收尾操作，不受阻止send/promote的设备暂停影响。

核对发送结果时保留原clientMsgId/eventKey。超时、成功数据无效或5xx后，不自动生成新UUID，也不重放非幂等动作。不承诺通用的执行恰好一次。Kit 0.0.1 对send/promote/withdraw成功响应严格要求**上述精确键集合**，promote/withdraw还核对意图与身份；这些路径新增响应字段不自动具备向后兼容性。


<a id="approvals"></a>

## 8. 审批、提问与计划

已配对的只读设备可读取。`GET /v1/approvals?status=pending` 返回 `{approvals: ApprovalView[]}`。`GET /v1/approvals/{id}` 返回 `{approval:{view:ApprovalView,body?,reviseCount?,cause?}}`；当前id为16位小写十六进制。

ApprovalView必需 `{id,status,targetLabel,toolName,summary,truncated,createdT,expiresT}`，可带targetId、attribution、decidedBy、provider、kind、questionCount、reviseCount、hint、options、optionsVaried、messageSupported与显示元数据。options为 `{id,kind,label,detail?,enabled,disabledReason?}`。body/cause只属于详情，不在SSE/列表摘要中提供。缺少cause/body不表示原始工具输入为空。全部正文都属于展示投影。

控制决定使用 `POST /v1/approvals/{id}`：

| 类型 | 请求体 | 说明 |
| --- | --- | --- |
| 普通审批 | `{decision:"allow_once"}` 或 `{decision:"deny",message?:string}` | 没有“始终允许”；message仅deny可带，最多500码元。 |
| 提问 | `{decision:"answer",answers:[...]}` | 每题一项，不漏答、不重复、不越界。 |
| 计划 | `{decision:"revise",message?:string}`（旧deny也表示打回） | 最多500码元；API不支持批准计划。 |
| 提问/计划 | `{decision:"release"}` | 交还终端。 |

answers每项为 `{question:integer,option:[integer,...]}` 或 `{question:integer,text:string}`，question与option下标均从0开始，自由文本最多500码元，选择范围、selectable和multiSelect遵循详情。提问body包含header、question、multiSelect及选项 `{label,description,preview?,selectable}`；计划body可带plan正文；改动详情可带投影后的path/kind/hunks。不要从占位文本猜隐藏选项。

成功返回 `{status}`，可附投影后的message/messageProjected、reviseCount、hint。展示返回的投影message，不假设输入原样保留。409 conflict可能表示已决定/过期/撤回，应刷新而非自动再提交。错误包括answer_invalid、wrong_kind、use_answer、plan_approve_unsupported。


<a id="transcript"></a>

## 9. 会话分页、条件读取与回执

`GET /v1/targets/{targetId}/transcript?limit=20&before=<cursor>` 是只读展示接口。limit为1–20、默认20；不传before读取最新页，读取旧页时原样回传nextBefore。页内从旧到新排列。sessionEpoch、revision、item id和游标均是不透明值。

```text
TranscriptPage = {status: string, sessionEpoch?: string, revision?: string,
  items: TranscriptItem[], nextBefore?: string, hasMore: boolean, partial: boolean,
  reason?: string, receiptUpdates?: {itemId: string, receipt: TranscriptReceipt}[]}
TranscriptItem = {id: string, role: string, text: string, t?: integer, truncated: boolean,
  projected?: boolean, receipt?: TranscriptReceipt, reason?: string, continuation?: string,
  displaySpans?: object[], displayMessage?: object}
TranscriptReceipt = {commandKey: string, origin: string, receiptState: string, reason?: string, eventKey?: string}
```

status为unavailable不等于空对话，应保留/回退到适当的回执历史。partial=true时可能没有items但游标已前移，空页不是历史末端。hasMore=false才结束；partial游标不前进时避免热循环。旧游标/续读令牌可返回410 reset，包括服务端重启后；丢弃后重拉最新页。目标消失可返回404。

接口仅提供投影后的user/assistant正文与gap，不提供原始tool/thinking/system载荷。不要重建隐藏内容，不要按正文/时间猜回执归属。receiptState当前为accepted/sent/done/unknown；存在eventKey时可精确关联本机发送。其他设备的消息不必暴露你的eventKey。

200页可带ETag。仅在仍保留同一缓存页、请求形状一致时发送If-None-Match，形状包括端点/设备/目标/before/limit/回执声明。304无正文，表示沿用缓存，不表示空页或鉴权被撤销。不能跨身份/范围/请求变更复用validator，也不要假设重启后仍有效。

最新页后补回执时，发送一个receiptEpoch和重复的receiptEventKey查询字段（最多20个receiptEventKey字段，规范化去重；值须非空、有效UTF-8、无控制字符且不超过256 UTF-8字节，编码声明预算16 KiB），不能与before混用，并保持一致规范化。receiptUpdates只可补丁更新同epoch/snapshot、eventKey在声明中的已加载user项；拒绝重复item id/冲突，不创建未知行、不按正文匹配。updates缺失/空数组均表示没有补丁。


<a id="continuation"></a>

## 10. 续读、账本历史与搜索

`GET /v1/targets/{targetId}/transcript/items/{itemId}?cont=<continuation>` 续读截断项。仅使用服务端签发、属于该item/session的令牌，不自造偏移。返回 `{status,sessionEpoch?,itemId?,text?,hasMore?,continuation?,reason?,displaySpans?}`，仅在身份匹配时按请求顺序合并。截断项没有continuation，不表示可以读取任意文件。

`GET /v1/targets/{targetId}/history?before=<cursor>&limit=20` 读取该目标的消息/回执账本，包含归档目标。limit默认20、最大50。返回 `{items,nextBefore?,hasMore,partial}`；页内从旧到新，分页向更旧历史。行包含 `{id,source,text,t?,kind?,replyTo?,targetId?,state?,...}`。inbox行可将ApiCommand字段**平铺同层**，不是command嵌套对象。游标是不透明位置，不是授权。partial空页不一定表示没有历史。

`GET /v1/search?q=<text>&limit=<n>` 搜索投影后的对话正文。q去首尾空白后须为2–128码元；limit为1–50，服务端默认20，Kit通常请求30。返回 `{results,partial,scanned:{targets,pages},skipped:[{targetId,reason}]}`。命中为 `{targetId,itemId,sessionEpoch,pageBefore?,role,t?,snippet,ranges,snippetDisplaySpans?}`；ranges为snippet内UTF-16单位的[起点,长度]。身份是targetId+itemId，不能只用itemId。用pageBefore读取所在会话页，缺省表示最新页。没有结果分页或穷尽全部历史的保证。partial且无结果不能显示“没有匹配”，并发搜索可返回409 busy。


<a id="terminal"></a>

## 11. 终端展示与显式输入

`GET /v1/targets/{id}/screen` 只读，返回 `{status,revision?,t?,cols?,rows?,lines?,truncated?,hidden?}`。unavailable不表示空终端，hidden内容须保持隐藏。这是投影视口，不是原始scrollback，也不是输入通道。Kit当前建议前台每2秒拉取，不构成服务端交付时限。

`POST /v1/targets/{id}/reveal` 请求 `{}`，要求control，在主机聚焦目标，不会开启输入会话。

输入接口：

| 方法/路径后缀 | 请求 | 成功/权限 |
| --- | --- | --- |
| GET `/input/session` | 无 | `{open:false}` 或 `{open:true,expiresT}`；只读可查 |
| POST `/input/session` | `{}` | `{expiresT}`；control，显式开启/续期，当前有效10分钟 |
| DELETE `/input/session` | `{}` | `{}`；control，关闭，已关也是成功 |
| POST `/keys` | `{keys:[...]}` **或** `{text:string}` | `{sent:integer}`；control且输入会话有效 |

keys为1–8个，白名单enter、esc、tab、up、down、left、right、backspace、ctrl+c、ctrl+d、space。text为一行、最多200码元、不含CR/LF，**不自动回车**；不能同时传keys和text。可能返回input_closed、approval_pending、pane_changed、read_only、busy。关闭会使在途开启/续期失效，Bridge重启关闭内存会话，权限与目标身份会被复核。keys/text响应丢失时执行结果不确定，绝不能自动重放。


<a id="self"></a>

## 12. 设备自管理与 APNs 登记

这些路由均需鉴权，只操作当前设备，不授予权限。

| 路由 | 请求 | 成功 |
| --- | --- | --- |
| PATCH `/v1/devices/self` | `{name:string}` | `{device:{id,name,paused,permission?}}` |
| PUT `/v1/devices/self` | `{paused:boolean}` | 同设备封套 |
| DELETE `/v1/devices/self` | `{}` | `{removed:true}`；令牌失效、事件流关闭 |
| PUT `/v1/devices/self/push` | `{token:string,environment:"development"|"production",localizationVersion?:integer}` | `{registered:true}` |
| DELETE `/v1/devices/self/push` | 不含登记秘密 | `{removed:true}` |

APNs token为64位十六进制（Kit要求小写，服务端规范化大小写），与设备Bearer不是同一种令牌。localizationVersion=1声明支持本地化推送键，省略则沿用旧载荷行为。登记成功不证明已投递。推送是否可用取决于Bridge配置；通知只提示刷新鉴权状态，不授权决定审批，也不授权重发结果未知的指令。


<a id="issue"></a>

## 13. Issue 任务预览与确认

这些端点为可选功能。**options路由本身**404时，Kit视为不支持；某个具体Issue的404不是同一信号。

| 路由 | 形状 |
| --- | --- |
| GET `/v1/issue-tasks/options` | `{createSupported,dispatchEnabled,github:{available,reason?,createSupported},sources:[{sourceId,repo}],targets:[{targetId,label,destinationVersion?,reason?,labelPlaceholder?}],maxPromptUnits,templateLanguages?}` |
| GET `/v1/issue-tasks/github/issues?sourceId=...&page=1` | `{items:[{number,title,state,updatedAt,url,titlePlaceholder?}],page}` |
| GET `/v1/issue-tasks/github/issues/{sourceId}/{number}` | `{number,title,state,updatedAt,url,body,sourceVersion,titlePlaceholder?,bodyPlaceholder?}` |
| POST `/v1/issue-tasks/preview` | control；请求见下；返回`{text,textDigest,destinationVersion,sourceVersion?}` |
| POST `/v1/issue-tasks` | control；同请求另加clientMsgId/textDigest；202 `{accepted,eventKey}` |

预览请求为 `{targetId,destinationVersion,source,instructions?,ackClosed?,templateLanguage?}`。source为 `{kind:"github",sourceId,number,version}` 或 `{kind:"manual",title,description?,referenceUrl?}`。来源/目的地版本是不透明值，从最新options/detail/preview原样取得版本和摘要，不由展示名生成。手工标题非空、单行、最多200码元，完整服务端拼接正文受maxPromptUnits约束。参考链接仅接受规范的HTTPS GitHub Issue URL。来源占位只供显示，不能作为可派发内容。

预览不等于提交。服务端生成权威正文，确认只发摘要，不发送客户端编辑后的模板。确认须带UUID clientMsgId，textDigest为64位小写十六进制。预览/确认保持同一来源、附言、语言和目标；请求字段白名单拒绝未知键。source_changed重取详情，destination_changed重取选项，preview_changed重新预览；预览改变须重新确认。ackClosed表示明确确认关闭Issue。202只表示入队，不表示执行。

已声明支持时templateLanguage可用zh/en，只翻译固定外壳，不翻译来源标题/正文/附言。缺省/null/未知字符串当前按zh处理。create响应不确定不等于创建失败，应保留身份，不自动重复createOnce。幂等重投会校验内容身份，可能返回idempotency_conflict，不能用同一标识更换来源/正文。


<a id="optional"></a>

## 14. 可选设备扩展（账户、用量、主机集成）

旧版或不同配置的Bridge可不提供这些路由，404/功能错误应与有效空快照区分。

| 路由 | 请求/响应 | 权限 |
| --- | --- | --- |
| GET `/v1/accounts` | 可带refresh=1；`{accounts:[AccountSnapshot],throttled?,claudeExperimental?}` | 读 |
| GET `/v1/usage` | window=5h/24h/7d/30d；UsageResponse | 读 |
| POST `/v1/usage/prices/refresh` | 无业务输入；`{result:"updated"|"current",pricing:UsagePricingInfo}`或错误/重试元数据 | control |
| GET `/v1/hooks/{claude|codex}` | `{installed,trust,stale?,lastFailure?,managedLocation?,configVersion?}` | 读 |
| POST `/v1/hooks/{claude|codex}` | `{action:"install"|"uninstall",expectedConfigVersion?:string}`；`{ok,error?}` | control |
| GET `/v1/accounts/claude/statusline` | `{installed:boolean}` | 读 |
| POST `/v1/accounts/claude/statusline` | `{action:"install"|"uninstall"}`；可选ok/settings/restored/warnings/error字段 | control |

字段形状见 [QuotaAccounts.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/QuotaAccounts.swift)。reset后缺usedPercent不表示用量0%；stale/error/awaiting_refresh不是新鲜余额。refresh=1当前按60秒节流，可返回缓存并标throttled=true。

账户可选字段 `planQuota`（仅 Qoder）：`"not_included"` 表示套餐额度总量确认为 0，显示“当前套餐不含套餐额度”；缺键或未知取值不显示，沿用 `CONTRIBUTING.md` 的兼容规范。

字段形状见 [Usage.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/Usage.swift)。coverage反映索引进度，不保证完整。estimate显式分版本，只解码已知version1，未知版本不应使整份响应失效。null/无价/partial/stale金额不等于已核验零费用，也不是账单；使用版本化estimate与来源，不用不完整旧prices自造总额。

安装/卸载钩子会改变主机配置，须有明确用户意图。managedLocation/configVersion用于归属检查，不静默覆盖别处安装；确认/版本冲突时刷新状态并明确确认。状态不可读不等于未安装，不将原始路径/错误内容当可信指令展示。完整可选测量/详情字段见下方公开schema目录。


<a id="deadlines"></a>

## 15. 请求期限、结果不确定与重试

Kit默认值属于客户端策略，不是服务端完成保证：

| 操作 | 当前期限 |
| --- | --- |
| 常规请求/TLS探测 |绝对10秒 |
| 配对POST |绝对15秒 |
| SSE响应头/首字节尝试 |绝对15秒 |
| SSE传输空闲兜底 |空闲90秒，不是流的绝对寿命 |
| 多地址刷新轮次辅助规则 |20秒 |

调用者显式传入的BridgeClient timeout优先于常规/单次data期限。仅设置timeoutInterval是空闲超时，不能约束持续滴答正文，须有绝对期限和取消。SSE响应头后需要活性检查与恢复，不是十秒后结束整条流。期限/轮询策略可独立于local-api/1演进。

结果分为明确成功、明确拒绝、未知。不能将超时/断线/成功响应无效改写成“未发送”。读取恢复可有界退避并复核身份；写入须按动作核对：用原标识查state/回执、刷新冲突资源，必要时等待新的明确动作。绝不自动重放终端输入或已消费配对码。即使两个地址属于同一个Bridge，换地址重试写操作仍可能重复生效。


<a id="compat"></a>

## 16. 兼容、升级与回退

**当前兼容行为。** 多数快照DTO忽略未知对象键，将不少status/reason保留为字符串，并将扩展设为可选。这不表示所有错误类型或未知枚举都能解码：transport及部分强类型枚举可能失败，已知但格式错误的SSE转为unknown，专用成功解码器可能严格。不要仅凭版本号或缺字段启用新的写功能。

始终区分：可选能力缺失与false、队列整组缺失与显式null、unknown与finished、unavailable/partial与空、执行不确定与从未派发。Kit为旧Bridge保留缺失permission的历史回退，但授权仍由服务端决定，新客户端不能从未知数据推断提权。

按实际端点/能力发现支持情况。旧端点404可禁用该可选功能，资源404不能禁用整个协议。操作UI接入前核对protocol，不向未确认的新身份发送秘密。产品升级仅在仍有效时保留Bridge身份、pin、设备归属与不透明游标；身份/授权变化要求reset/重配时不能静默迁移权限。

Kit tag不可移动，修复使用新tag，消费者固定所选版本。回退可能移除可选字段/端点或使分页/会话失效：保留草稿、取消过时代次的在途任务、刷新快照，保持不支持的控件不可用。本文和公开Kit均不授权公开引擎、修改主机配置、轮换秘密或自动降级。超出该核对基线的兼容承诺须经过明确审查的协议决定。


<a id="schemas"></a>

## 17. 公开 schema 目录

上文精简线形状说明对接契约。以下固定tag的公开定义补充嵌套/可选字段与解码例外，属于本文参考内容，不要求访问私有仓库；应按线DTO读取，不能将每个Swift计算属性当成线字段。这是有源码依据的schema目录，不是机器可读JSON Schema，也不表示所有字段都必需。

| 公开来源 | 覆盖 |
| --- | --- |
| [Models.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/Models.swift) | 健康/state/目标/设备/历史/审批/会话/搜索/屏幕/输入线DTO |
| [ThreadArchive.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/ThreadArchive.swift) | 观察DTO与保守的证据消费 |
| [Constants.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/Constants.swift) | 协议、路径、单位、限制、事件/状态名 |
| [SSEParser.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/SSEParser.swift) | 分帧与事件载荷解码 |
| [MessageActions.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/MessageActions.swift) | 发送/队列意图与严格成功/错误解码 |
| [QueueStatus.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/QueueStatus.swift) | 平铺队列字段与停止分类解码 |
| [TranscriptSync.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/TranscriptSync.swift) | 续读段、ETag结果处理与分页辅助规则 |
| [TranscriptReceiptBackfill.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/TranscriptReceiptBackfill.swift) | 回执声明与安全补丁接纳 |
| [TargetHistory.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/TargetHistory.swift) | 账本行/页形状及inbox平铺指令字段 |
| [IssueTasks.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/IssueTasks.swift) | Issue选项/列表/详情/预览/创建请求响应 |
| [Usage.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/Usage.swift) | 用量及estimate v1的嵌套测量/来源字段 |
| [QuotaAccounts.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/QuotaAccounts.swift) | 账户额度/窗口及状态行字段 |
| [HookInstallation.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/HookInstallation.swift) | 安装状态/归属/结果定义 |
| [BridgeDisplayMessage.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/BridgeDisplayMessage.swift) | 语义显示消息扩展 |
| [BridgeDisplayText.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/BridgeDisplayText.swift) | 容错显示范围与安全本地化投影 |
| [BridgeClient.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/BridgeClient.swift) | 客户端请求、传输设置和期限应用 |
| [PairRoute.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/PairRoute.swift) | 配对确认与结果未知处理 |
| [Pinning.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/Pinning.swift) | SPKI格式、pin比较与拒绝重定向 |
| [ReconnectPolicy.swift](https://github.com/forsakesoul/palmhelm-kit/blob/0.0.1/Sources/PalmhelmKit/ReconnectPolicy.swift) | 有界客户端重连辅助规则 |
