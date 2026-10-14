# Bot Screen

## 使用

连接 Hermes 服务并选择角色后，点击聊天顶部的「打开电脑」，或按 ⌘⇧D。每个 profile 的电脑独立；在同一个角色内换聊天不会换电脑。

1. 未启动时点击「启动电脑」。运行后以只读模式观看实时桌面。
2. 需要登录或其他人工操作时点击「接管」，键盘和鼠标作用于远端电脑。Agent 的电脑操作受服务端 lease 阻止。
3. 完成人工步骤后点击「交还 Agent」，然后在聊天里告诉 Agent 继续。客户端不会自动发消息。
4. 分栏之间可拖动调整宽度；右上角可放大电脑，再返回聊天。
5. 关闭面板保留远端桌面运行，并尝试交还本人控制权。「停止」会关闭桌面中的应用，界面要求确认；不能停止另人持有的电脑。

Wi-Fi 中断或 Mac 睡眠期间不自动交还。主 RPC 连接重建后，原控制权可能显示为另一位用户；如果这是你此前的接管，确认重新接管后即可交还。释放结果未知时保留提醒，切回对应角色查询，不把提醒当成释放成功。

## 后端准备

需要支持 `display.status/start/stop/observe/lease.*` 的 Hermes 服务，和可运行 TigerVNC / Xfce 的 Linux 主机或支持桌面的 terminal sandbox。支持程度以实际接口为准，不能只看广告版本号。协议源码参考及字段见 [协议说明](PROTOCOL.md#bot-screen-扩展)。

在运行 Hermes 的 Linux 主机上，使用该 profile 对应 CLI：

```sh
hermes computer-use screen status
hermes computer-use screen install
hermes computer-use screen start
# 非默认角色（例如 research）
hermes -p research computer-use screen status
hermes -p research computer-use screen install
```

客户端不会自动安装包。网关和 terminal sandbox 是不同安装位置：sandbox 缺少组件时，应按服务返回的 `blocker` 准备相应桌面镜像，不在网关主机上安装来代替。

如果希望 Agent 的浏览器操作也显示在这台电脑上，按官方配置设置 `browser.headed: true`。仅启动桌面不保证已有 headless 浏览器变成可见窗口。桌面和浏览器登录状态由服务端管理；客户端不复制 cookies、记忆或配置。

本功能是 Linux 桌面查看和控制，不在 Mac 启动 VM，也不提供 macOS 本地应用控制。profile 的桌面会话本身不构成 VM 隔离；容器/VM 的部署边界由后端决定。

## 开发验收

`./script/test.sh` 启动严格的本地模拟服务并运行回归测试。模拟桌面为明确的 RFB 3.8 色块测试图，不是真实 Xfce；模拟服务按 RPC transport 签发 viewer 身份，单次使用桌面票据，服务端拒绝非 lease 持有人的输入。

`BotScreenViewerIntegrationTests` 使用真实 WKWebView 与打包的 noVNC，检查握手、canvas 像素、键盘输入限制和截图。`BotScreenLayoutTests` 用实际 NSHostingView 验证放大、恢复、窄窗口和电脑视图不重建。

Debug 应用可在隔离配置中进行 UI 验收；下述入口只编译到 Debug，只接受 loopback fixture 地址，不读取或写入用户的真实 Keychain 凭据：

```sh
/tmp/hermes-mac-test-venv/bin/python script/mock_server.py --port 19119
# 另一个终端，先完成 ./script/build_and_run.sh --build
open -n DerivedData/Build/Products/Debug/HermesMac.app --args --bot-screen-fixture http://127.0.0.1:19119
```

验收证据和真实服务限制见 [验证记录](VALIDATION.md)。


### 2026-10-14 生命周期回归

WebKit 消息处理器改用弱代理，正常拆卸仍执行 JavaScript dispose、停止加载及移除处理器。Coordinator 析构也取消超时任务，并对仍被宿主持有的 WebView 安排主线程清理。

`testCoordinatorReleasesWithoutExplicitDismantleWhileWebViewSurvives` 验证不调用显式拆卸时 Coordinator 可以释放；原有真实 WebKit/RFB 测试继续验证消息桥接、画面和输入。尚未进行 Instruments 或真实桌面长期内存曲线测量，详见 [验证记录](VALIDATION.md)。
