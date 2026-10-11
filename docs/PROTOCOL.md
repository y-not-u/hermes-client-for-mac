# 协议约定与实现边界

官方源码基线：[c57331677d7fc46298a7159cf3a650853f0966c5](https://github.com/NousResearch/hermes-agent/tree/c57331677d7fc46298a7159cf3a650853f0966c5)。本文描述当前客户端实际使用的契约。客户端没有启动时的 git revision 校验；方法不可用、响应非 JSON 或原生认证能力缺失时会显示错误并提示检查版本。

## HTTP

| 接口 | 用途与归属 |
| --- | --- |
| GET `/api/status` | REST 连通性、`auth_required` 与 `auth_flows` 能力 |
| GET `/api/profiles` | `profiles` 列表，按服务保存显示顺序 |
| GET `/api/sessions?profile=…` | 当前 profile 的历史，40 条分页 |
| GET `/api/sessions/search?profile=…&q=…` | 搜索当前 profile 历史 |
| GET `/api/sessions/{storedID}/messages?profile=…` | 首屏读取最新历史、按需读取更早记录，每页 20 条，`inline_images=false` |
| PATCH `/api/sessions/{storedID}` | JSON body 含 `profile` 和 `title`，重命名 |
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
| `prompt.submit` | `profile`, 运行时 `session_id`, `text` |
| `session.interrupt` | `profile`, 运行时 `session_id`，只停止目标任务 |
| 服务端 `approval` 请求 | 卡片显示服务给出的选项；JSON-RPC response 使用原请求 ID 和 `result.choice` |

源码参考中的 `idempotency_key`（create）和 `inline_images`（resume）是可选扩展参数，但实测 Hermes 0.21.5 严格拒绝这些额外 RPC 参数。客户端统一省略它们，保持同一套请求；没有失败后切换协议或自动再次 create 的逻辑，也不依赖幂等键进行重试。

持久 ID 与运行时 ID 分开维护。会话归属键为 `(service, profile, storedID)`；事件 `params.session_id` 通过运行时路由表归属该键。切换界面不改变路由。每次连接建立新 generation，旧连接和迟到 REST 回包不能修改新服务状态。绑定运行时 ID 前到达的事件有数量受限的缓冲。

事件以 `method=event`、`params.type` 和 `params.payload` 传输。客户端处理 `message.start/delta/interim/complete`、`tool.start/complete`、`error`、`request.cancel`；未知事件忽略。未知服务端请求返回 JSON-RPC `-32601` 并提示不支持，不批准工具。流式更新约 40 ms 合并刷新，空闲时没有持续高频轮询。

## 恢复与数据

断线保留可见消息；生成中的会话标记结果不确定。自动重连按 2、4、8、16、30 秒退避，重新查询 profiles 和已打开会话 snapshot，包括后台会话与未完成审批。达到重试上限后提示手动重连。不能 resume 时尝试读取历史，并显示只读原因，不尝试其他协议。

恢复时先通过 REST 读取最近 20 条原始记录，再通过 `session.resume(omit_messages=true)` 获取较新的运行状态与 inflight。更早历史仅在点击“加载更早消息”时分页读取；关闭 REST 内联图片，只保留非隐藏的 user/assistant 文本，不保留历史 tool/system 记录。分页 offset 按服务端原始记录数推进，不能按过滤后的可见消息数推进。当前 REST 接口不支持按 role 排除工具结果，所以小页中仍可能传输工具原文，但不会通过 WebSocket 重复传输整段历史。运行期间的工具状态与审批仍照常处理。加载指示器使用覆盖层，避免反复插入消息列表而改变滚动布局。

参考 [Wave 的 gateway client](https://github.com/RenanQueiroz/wave-for-hermes/blob/main/src/services/gateway/gateway-client.ts) 的 metadata-only resume，以及 [官方 REST 历史分页接口](https://github.com/NousResearch/hermes-agent/blob/c57331677d7fc46298a7159cf3a650853f0966c5/hermes_cli/web_routers/sessions.py)。不通过扩大 WebSocket 消息上限来掩盖完整历史传输问题。

切换服务会断开旧连接并丢弃运行时映射，但 `close_on_disconnect=false` 不要求服务端停止任务。UserDefaults 中的草稿、选中会话和 profile 顺序按服务隔离；Keychain 中凭据同样按规范化地址隔离。没有导出或复制服务端配置、记忆、数据库的功能。

源码契约依据为官方 `hermes_cli/web_routers/{profiles,sessions,status,chat_ws}.py`、`hermes_cli/dashboard_auth/{routes,native_flow}.py`、`plugins/dashboard_auth/basic/__init__.py` 和 `tui_gateway` 的 session/prompt 方法。真实测试服务返回版本 0.21.5，未报告 git SHA，不能称固定参考 revision 已实机验证。

### 流式恢复的水位边界

当前后端快照没有与通知流共享的服务端水位。客户端记录接收次序，以 inflight 快照覆盖此前流式文字，工具事件按稳定 ID 保留；历史请求开始后、恢复响应之前到达的 `message.complete` 仍按最终全文校正显示，相同末尾全文不重复追加。REST 页面与运行状态不是原子快照。快照构建与响应之间并发发出的少量 delta 可能暂未显示，故本版不能声称严格无损的事件重放。后续需将服务端快照水位与 `session.events.since` 协调，不能把本地接收次序当作服务端事件序号。
