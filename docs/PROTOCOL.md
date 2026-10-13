# 协议约定与实现边界

官方源码基线：[c57331677d7fc46298a7159cf3a650853f0966c5](https://github.com/NousResearch/hermes-agent/tree/c57331677d7fc46298a7159cf3a650853f0966c5)。本文描述当前客户端实际使用的契约。客户端没有启动时的 git revision 校验；方法不可用、响应非 JSON 或原生认证能力缺失时会显示错误并提示检查版本。

## HTTP

| 接口 | 用途与归属 |
| --- | --- |
| GET `/api/status` | REST 连通性、`auth_required` 与 `auth_flows` 能力 |
| GET `/api/profiles` | `profiles` 列表，按服务保存显示顺序 |
| GET `/api/sessions?profile=…&exclude_sources=cron` | 当前 profile 的历史，排除定时任务运行会话，40 条分页 |
| GET `/api/sessions/search?profile=…&q=…&exclude_sources=cron` | 搜索当前 profile 历史，排除定时任务运行会话 |
| GET `/api/sessions/{storedID}/messages?profile=…` | 首屏读取最新历史、按需读取更早记录，每页 20 条，`inline_images=false` |
| GET `/api/fs/read-data-url?path=…&profile=…&session_id=…` | 按助手回答中的 `MEDIA:` 路径读取图片，返回 `dataUrl`；使用持久会话 ID 和现有认证 |
| PATCH `/api/sessions/{storedID}` | JSON body 含 `profile` 和 `title`，重命名 |
| PATCH `/api/sessions/{storedID}` | JSON body 含 `profile` 和 `archived=true`，归档；列表与搜索隐藏归档记录 |
| DELETE `/api/sessions/{storedID}?profile=…` | 删除确认后移除所属 profile 的会话历史 |
| GET `/auth/native/authorize` | 系统浏览器，随机 loopback 回调、state、S256 PKCE |
| POST `/auth/native/token` | `code` 和 `code_verifier` 换取凭据 |
| POST `/auth/native/refresh` | `refresh_token` 和 `provider` 刷新，合并并发刷新请求 |
| POST `/api/auth/ws-ticket` | 远程 Bearer 凭据换取 WebSocket 票据 |

服务地址规范化后成为身份的一部分；不同 scheme、host、port、path 视为不同服务。地址不接受 userinfo、query 或 fragment。REST 全部在 `HermesClient`，视图不拼接协议。

## WebSocket JSON-RPC

共享 `/api/ws` 连接。loopback 使用 `?token=…`；官方认证模式使用 `?ticket=…`。连接后首先调用 `client.capabilities`，声明 `server_requests=true`。请求按 JSON-RPC ID 匹配 continuation，90 秒超时；socket 断开会让所有等待请求失败，不自动重发。

| 方法 | 参数与行为 |
| --- | --- |
| `session.create` | `profile`, `source=dashboard`, `close_on_disconnect=false` |
| `session.resume` | `profile`, 持久 `session_id`, `omit_messages=true`；只获取运行状态、inflight 和待处理请求，不传输完整历史 |
| `prompt.submit` | `profile`, 运行时 `session_id`, `text`；运行中的“完成后发送”额外传 `queued=true` |
| `session.redirect` | `profile`, 运行时 `session_id`, `text`，改向当前回合；工具执行中后端转为 steer |
| `session.steer` | 相同参数，在下一工具边界注入补充要求 |
| `model.options` | `profile`，已打开会话额外传运行时 `session_id`；读取 `providers` 和当前 `model/provider`，手动刷新传 `refresh=true` |
| `config.set` | `profile`, 运行时 `session_id`, `key=model`, `value=<model> --provider <slug> --session`；收到 `confirm_required` 时展示服务端提示，用户确认后才额外传 `confirm_expensive_model=true` |
| `session.interrupt` | `profile`, 运行时 `session_id`，只停止目标任务 |
| 服务端 `approval` 请求 | 卡片显示服务给出的选项；带 `params.request_id` 时调用 `approval.respond(session_id, request_id, choice)`，收到 `resolved > 0` 后移除卡片；无队列 ID 的旧请求使用原 JSON-RPC ID 和 `result.choice` 响应 |

源码参考中的 `idempotency_key`（create）和 `inline_images`（resume）是可选扩展参数，但实测 Hermes 0.21.5 严格拒绝这些额外 RPC 参数。客户端统一省略它们，保持同一套请求；没有失败后切换协议或自动再次 create 的逻辑，也不依赖幂等键进行重试。

运行中的当前会话可以继续发送，其他同 profile 会话仍受互斥限制。默认尝试 `session.redirect`；仅收到 `rejected`、方法不存在（`-32601`）或不支持能力（`4010`）时尝试 `session.steer`，两者明确拒绝后以 `prompt.submit(queued=true)` 提交下一轮。显式“完成后发送”直接走后者。严格拒绝扩展参数的老服务会显示提交失败并保留可恢复草稿，不退回可能中断任务的普通 submit。超时、断线、未知响应不自动重发。消息旁的“已提交改向/引导”表示服务接收，不能保证模型已经采用。

客户端在提交改向前分隔原流式回答，之后的回答显示在补充消息下；排队保持当前回答的流式归属。`inflight.corrections` 用于恢复运行中补充消息。RPC 错误保留数值 code，仅以明确的拒绝判断后续接口尝试。

持久 ID 与运行时 ID 分开维护。会话归属键为 `(service, profile, storedID)`；事件 `params.session_id` 通过运行时路由表归属该键。切换界面不改变路由。每次连接建立新 generation，旧连接和迟到 REST 回包不能修改新服务状态。绑定运行时 ID 前到达的事件有数量受限的缓冲。

事件以 `method=event`、`params.type` 和 `params.payload` 传输。客户端处理 `message.start/delta/interim/complete`、`tool.start/complete`、`error`、`request.cancel`；未知事件忽略。未知服务端请求返回 JSON-RPC `-32601` 并提示不支持，不批准工具。流式更新约 40 ms 合并刷新，空闲时没有持续高频轮询。

## 恢复与数据

断线保留可见消息；生成中的会话标记结果不确定。自动重连按 2、4、8、16、30 秒退避，重新查询 profiles 和已打开会话 snapshot，包括后台会话与未完成审批。达到重试上限后提示手动重连。不能 resume 时尝试读取历史，并显示只读原因，不尝试其他协议。

恢复时先通过 REST 读取最近 20 条原始记录，再通过 `session.resume(omit_messages=true)` 获取较新的运行状态与 inflight。更早历史仅在点击“加载更早消息”时分页读取；关闭 REST 内联图片，只保留非隐藏的 user/assistant 文本，不保留历史 tool/system 记录。分页 offset 按服务端原始记录数推进，不能按过滤后的可见消息数推进。当前 REST 接口不支持按 role 排除工具结果，所以小页中仍可能传输工具原文，但不会通过 WebSocket 重复传输整段历史。运行期间的工具状态与审批仍照常处理。加载指示器使用覆盖层，避免反复插入消息列表而改变滚动布局。

参考 [Wave 的 gateway client](https://github.com/RenanQueiroz/wave-for-hermes/blob/main/src/services/gateway/gateway-client.ts) 的 metadata-only resume，以及 [官方 REST 历史分页接口](https://github.com/NousResearch/hermes-agent/blob/c57331677d7fc46298a7159cf3a650853f0966c5/hermes_cli/web_routers/sessions.py)。不通过扩大 WebSocket 消息上限来掩盖完整历史传输问题。

切换服务会断开旧连接并丢弃运行时映射，但 `close_on_disconnect=false` 不要求服务端停止任务。UserDefaults 中的草稿、选中会话和 profile 顺序按服务隔离；Keychain 中凭据同样按规范化地址隔离。没有导出或复制服务端配置、记忆、数据库的功能。

## 回答中的远程图片

助手回答里的 `MEDIA:/absolute/path.png` 或 `MEDIA:~/path.png` 显示为图片卡片，支持 png、jpg/jpeg、gif、webp、bmp。带空格的路径可用单引号、双引号或反引号包住路径。代码围栏、引用、行内代码示例、用户消息和工具详情不会触发图片读取；非图片指令保留为文字。图片卡片保留在正文中的位置，同一回答里的相同路径只展示一次。

图片请求沿用 `HermesClient.rest` 的 Bearer/session token 认证、令牌刷新与服务地址前缀。只请求用户配置的服务上的 `/api/fs/read-data-url`，传 `profile` 和持久 `session_id`，不向其他站点发送凭据、不回退到更宽的文件读取接口。文件、会话或接口不存在、权限拒绝、大小限制等失败会保留远程路径并显示重试按钮。客户端接受最多 16 MB 的 base64 图片，解码尺寸最多 4000 万像素；预览缩略图最长边 1600 像素。gif 预览为静态首帧。

原图缓存在 `~/Library/Caches/com.hermes.mac/Media`，缓存键包含 `(service, profile, storedID, messageID, path)`，避免不同会话复用 scratch 路径时串图。并发读取合并；缓存可跨应用重启读取，上限 200 MB，按保存时间淘汰旧文件。下载过的图片可在源文件被清理后继续查看，直到本地缓存被淘汰。点击图片打开大图并缩放，保存按钮导出原图。大图由聊天根视图呈现，查看期间暂停聊天自动滚动。

源码参考为官方 [文件路由](https://github.com/NousResearch/hermes-agent/blob/c57331677d7fc46298a7159cf3a650853f0966c5/hermes_cli/web_routers/files.py#L907)。这使用已有 Hermes 能力，无需修改远程服务；老版本没有该接口时显示失败提示。

源码契约依据为官方 `hermes_cli/web_routers/{profiles,sessions,status,chat_ws}.py`、`hermes_cli/dashboard_auth/{routes,native_flow}.py`、`plugins/dashboard_auth/basic/__init__.py` 和 `tui_gateway` 的 session/prompt 方法。真实测试服务返回版本 0.21.5，未报告 git SHA，不能称固定参考 revision 已实机验证。

### 流式恢复的水位边界

当前后端快照没有与通知流共享的服务端水位。客户端记录接收次序，以 inflight 快照覆盖此前流式文字，工具事件按稳定 ID 保留；历史请求开始后、恢复响应之前到达的 `message.complete` 仍按最终全文校正显示，相同末尾全文不重复追加。REST 页面与运行状态不是原子快照。快照构建与响应之间并发发出的少量 delta 可能暂未显示，故本版不能声称严格无损的事件重放。后续需将服务端快照水位与 `session.events.since` 协调，不能把本地接收次序当作服务端事件序号。

## 输入栏模型选择

发送按钮左侧使用原生菜单，按提供商分组；只展示已配置提供商的模型，标记当前选择并禁用服务标记不可用的模型。列表和状态按服务、角色、持久会话隔离，旧请求不能覆盖切换后的模型状态。未连接、只读、角色运行中或状态不确定时禁止切换；切换请求期间禁止同角色发送。切换失败保留原模型和草稿，菜单显示错误并支持刷新。请求超时不会自动重发。

尚未创建会话时，选择模型先调用 `session.create`，将草稿移入新会话，然后执行会话级 `config.set`；不会向模型发送聊天消息，也不会写角色默认模型。此流程对照基线源码 `tui_gateway/methods_complete.py` 的 `model.options` 和 `methods_config_set.py` 的模型 setter。真实服务已验证模型列表；切换、确认和失败行为通过模拟服务集成测试验证。

`config.set` 的模型字符串由服务端按空白拆分，名称不加 shell 引号；引号会被当作提供商 ID 的一部分。模拟服务采用相同规则，并通过拒绝带引号的提供商名称的回归用例验证。

## Bot Screen 扩展

桌面契约单独对照官方 revision [`8f817911723e3ec13e7f47fc022fdcc9e2149354`](https://github.com/NousResearch/hermes-agent/tree/8f817911723e3ec13e7f47fc022fdcc9e2149354)。源码依据为 `tui_gateway/methods_display.py`、`hermes_cli/web_routers/display.py`、`tools/bot_desktop/{runtime,lease}.py` 及 `apps/desktop/src/plugins/hermes-bots/screen-pane.tsx`。这不改变此前聊天协议基线，也不等于已验证真实服务运行此 revision。

| 方法 | 参数与返回 |
| --- | --- |
| `display.status` | `profile`；返回 `profile_key`、`supported`、`installed`、`running`、`missing`、`geometry`、`placement`、`blocker`、`install_command`、`lease` |
| `display.start` | `profile`；返回完整状态，不自动安装包 |
| `display.stop` | `profile`；有人工控制权时拒绝，客户端先交还本人 lease；不传 `force` |
| `display.observe` | `profile`，同 RPC transport 重建桌面流时可加 `viewer_id`；返回完整状态与 `ticket`、`path=/api/display/ws`、服务签发的 `viewer_id` |
| `display.lease.acquire` | `profile`, `viewer_id`, `reason`；返回 `lease`；替换另人控制权必须经过界面明确确认 |
| `display.lease.release` | `profile`, `viewer_id`；仅释放本人，不传 `force`；返回 `lease` |

观看 socket 使用 `ws(s)://<服务及代理前缀>/api/display/ws?display_ticket=…`。票据是通过已有认证 RPC 获取的 30 秒单次票据；不能把 `/api/auth/ws-ticket` 的主连接票据当成桌面票据。网关给出的路径只接受固定 endpoint，不能指定其他主机；URLQueryItem 负责票据编码。长期 token 不传给 WebView。

`lease.holder` 为 `agent` 或 `human`；`viewer_hash` 是服务签发的 viewer ID 的 SHA-256 前 12 位。客户端用 hash 判断本人控制权，不从公开 `lease.viewer_id` 获取能力（官方公开值为 null）。控制权事件是全局 `event`，`params.type=display.lease`，`payload={profile_key,lease}`，不依赖聊天的 `session_id`；`profile_key` 是不透明的 home 身份，不能假设等于 profile 名称。

状态按 `(service, profile)` 缓存。面板打开时每 10 秒查询运行状态；关闭时不轮询。观看流断开后尝试重新获取单次票据；握手超过 15 秒按失败处理。接管/启动等变更请求不自动重试。迟到接管的明确成功结果会用原 viewer 能力补偿交还；未知结果留下可关闭的控制权提醒，成功状态查询不会隐藏它。

同一 RPC transport 的观看流重连可以保留 viewer 身份。RPC 断线后 viewer 需重新签发，旧 human lease 仍由服务保留；用户需明确确认「接管」恢复控制权，再交还。不自动用 `force` 清理旧 lease。切换 profile 或服务、关闭面板/主窗口、正常退出会尝试释放本人控制权；退出最多等待 3 秒，超时不声称释放成功。

显示层是原生 SwiftUI 外壳和 WKWebView 的本地 `hermes-botscreen://viewer/` 资源。noVNC 1.6.0 及 pako 固定版本离线打包，许可证和下载校验在 `Resources/BotScreen/VENDOR.md`。页面只加载本地模块，禁止外部导航和来自其他 frame/origin 的消息；票据 URL 不写日志，显示错误不包含 WebSocket 的原始地址。
