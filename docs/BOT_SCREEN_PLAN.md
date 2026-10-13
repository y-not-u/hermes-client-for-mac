# Bot Screen 实现与验收计划

## 目标与范围

在现有原生 macOS 客户端中，实现聊天旁观看 Hermes 的 Linux 桌面，并由用户接管、完成登录后交还 Agent 的流程。桌面归属为 `(service, profile)`，不是聊天会话；切换聊天不应重建同一 profile 的桌面。第一版不在 Mac 启动 VM，不自动安装远端包，不配置远端浏览器，不在交还后自动发送聊天消息。

官方 Bot Screen 提供桌面进程、一次性观看票据和服务端控制权。客户端实现 SwiftUI 面板、现有认证连接上的 `display.*` RPC、内嵌 WKWebView 与本地 noVNC。桌面像素和输入使用独立 WebSocket，不经过聊天 JSON-RPC。不同 profile 的 Xfce 会话不等于虚拟机安全隔离。

## 分工

- `desktop_protocol`：核对固定官方源码 revision；模型、状态与网络生命周期、AppStore 接线。
- `desktop_viewer`：固定版本 noVNC 及许可证、本地资源、WKWebView 窄桥和状态回调。
- `desktop_ui`：聊天入口、可调整的并排布局、放大视图、桌面操作和错误/缺失能力状态。
- 主 agent：计划、资源构建配置、严格模拟服务和集成测试、代码审查、构建启动及最终验收。

## 实现约束

1. 所有长期认证凭据留在 Swift；WebView 只得到短期单次桌面观看票据。
2. 未确认本人持有 lease 时保持只读；以服务端状态和事件为准。桌面和聊天的状态分开。
3. 正常关闭/切换面板时释放本人控制权，失败则告知；意外网络中断不自动释放。重连重新查询状态、申请新观看票据，不重放接管等变更请求。
4. 每次服务/profile/观看连接切换均隔离迟到结果和 WebView 回调，不能串图或把输入投给其他 profile。
5. 老后端不支持方法时显示升级说明；Linux 缺包显示主机 CLI 指引；不虚构正常直播状态。
6. noVNC 离线打包，限制 WebView 导航和原生桥消息来源。SwiftPM 和 Xcode 产物均包含资源。
7. 接管、交还和停止有独立等待/失败状态；停止不得强制抢走另一人的控制权。

## 验收

- 协议：实际 URLSession RPC 集成覆盖启动、观看、接管/交还、停止、另一人控制、缺失能力/组件、迟到响应、断线和重新连接。
- 显示：实际 WKWebView 加载本地 noVNC 并与最小 RFB 3.8 模拟服务器握手、接收像素，证明打包与渲染链路；验证观看态与接管态输入边界。
- 回归：既有聊天、模型切换、历史与认证测试保持通过。
- 应用：生成 Xcode 工程，使用项目构建运行脚本完成签名 Debug 构建和启动，检查实际界面入口、面板及错误状态。
- 记录：区分模拟服务验收、实际应用 UI 验收、真实 Linux Xfce 服务验收；没有实际执行的项目不标为通过。若当前服务无法验证 Bot Screen，记录所需后端条件和人工检查步骤。

官方依据：[Bot Screen 文档](https://hermes-agent.nousresearch.com/docs/user-guide/features/bot-screen)及 [已合并的实现 PR](https://github.com/NousResearch/hermes-agent/pull/108914)。具体源码 SHA 和字段在协议说明中记录。
