# 验证与人工验收

## 证据分层

2026-10-11 验证记录：`script/test.sh` 的 10 项本地模拟测试通过；10:04:42（Asia/Singapore）真实服务的 `LiveConnectionTests` 1 项测试通过。另有官方固定 revision 源码契约对照和 macOS 构建/启动验证。mock 使用 aiohttp，真实测试使用用户提供的局域网服务；两者的证据分开记录。

真实服务广告 Hermes 0.21.5、`native_pkce` 和 4 个 profiles。已通过 native PKCE broker、loopback 回调、token 交换与 Keychain 保存、WebSocket ticket、profile 加载、历史读取与恢复、两个 profiles 并行真实 A/B marker 回复、草稿隔离、后台未读、重命名及重连恢复。用户确认系统浏览器登录成功；独立 live test 中 broker 登录表单由 HTTP 辅助完成，因此不称完整 UI 自动化。macOS 本地网络权限已开启，构建的 Info.plist 本地网络配置已验证。

服务仅返回版本号，未报告 git SHA，不能称参考 revision `c57331677d7fc46298a7159cf3a650853f0966c5` 已实机验证。真实工具审批、中断、断网、服务重启、token 到期及中文输入法尚未完整实测；仍需下面的人工清单。文档不记录真实服务地址、密码或令牌。

```sh
./script/build_and_run.sh --build
./script/build_and_run.sh --verify
./script/test.sh
```

`--verify` 只检查应用启动后进程存在，不代替界面交互检查。`script/test.sh` 不使用真实 Hermes 配置或模型凭据。SwiftPM 是测试入口，Xcode 工程是应用构建入口。

### 2026-10-12 远程图片验证

`./script/test.sh`：29 项测试通过（10 项模拟协议集成、8 项图片测试、11 项状态测试），0 失败；未设置真实服务变量的 live test 跳过。图片测试覆盖指令顺序/去重、代码示例隔离、含空格与中文等路径编码、Bearer/session token 请求、HTTP 401/403/404/413、数据大小与解码校验、缓存并发合并、跨重启命中、服务/profile/会话/消息隔离、损坏缓存恢复及磁盘容量限制。

通过签名应用和现有登录，在用户已有 financial 会话读取真实 `MEDIA:` 图片，确认 1600 × 1080 的热力图在聊天中展示。通过原生界面验证打开大图、缩放至 140%、重置适合窗口、关闭预览和原图保存；临时导出的 PNG 为 150,043 字节，与本地缓存原图逐字节一致。验证未新增测试聊天、调用模型或修改远程服务。另验证 Xcode 构建和应用启动成功。

首次验证期间曾出现聊天懒加载布局主线程持续忙碌。已将大图呈现移至聊天根视图、限制图片卡片高度，并在大图打开期间暂停自动滚动；重新构建后上述界面操作正常，空闲进程 CPU 回到 0%。这验证了当前会话的交互，未声称已覆盖所有流式生成与模态窗口的并发情况。

### 2026-10-12 代码块布局修复

针对 `ScrollView → LazyVStack → MarkdownView → 水平 ScrollView` 的重复测量路径，将代码内容替换为 `NSScrollView + NSTextView`。SwiftUI 只接收与行宽无关的有限视口高度（最多 360 pt）；长行横向滚动，长代码纵向滚动，保留选择和复制。文本尺寸只在内容变化时测量，滚动条配置仅在属性有差异时写入。

`./script/test.sh`：41 项通过，1 项真实服务测试跳过，0 失败。新增宿主窗口布局回归覆盖超长行、多代码块、未闭合流式围栏、320/900 pt 宽度反复切换及可选择的原生代码视图。12 次更新与布局约 0.26 秒完成。另通过 Xcode 构建、`--verify` 启动检查，以及真实服务已有会话之间切换和恢复的界面检查。未重新采集用户原始卡死场景的火焰图，未新增远程测试消息。

### 2026-10-13 工具列表收起与日志布局修复

工具列表改为固定 240 pt 视口和直接测量的 `VStack`，展开/收起去除结构布局动画，工具详情整行可点击。日志复用有限高度的 `NSScrollView + NSTextView`，保留选择、复制和双向滚动；文本视图固定测量得到的最小内容宽度，防止 AppKit 在视口调整时截断长行。

`swift test --filter StateTests`：21 项通过，0 失败。新增工具详情布局回归使用超长行及 500 行日志，交替以 320/900 pt 宽度展开与收起，验证日志视口不超过 360 pt、长行可横向到达、收起移除日志视图；12 次布局约 0.41 秒完成。`./script/build_and_run.sh --verify` 构建和启动通过，原有会话可恢复。

修复前通过辅助功能按钮成功收起用户当前的工具列表，未复现持续卡死。任务在检查期间完成，重载后的服务历史未保留工具活动，因此新版真实运行中的工具列表交互尚未实测；本次证据为布局回归和应用构建/启动，不声称已复现并确认原始卡死根因。

### 2026-10-14 Bot Screen

先按 [实现计划](BOT_SCREEN_PLAN.md) 划分协议、WebKit 显示与原生 UI 三个 subagent，主 agent 完成集成、测试和验收。桌面契约固定对照官方 `8f817911723e3ec13e7f47fc022fdcc9e2149354`；noVNC 1.6.0 本地资源在 SwiftPM 和 Xcode 中均已打包。

`./script/test.sh`：81 项测试，80 项通过，1 项 opt-in 真实服务测试跳过，0 失败。新增桌面测试覆盖实际 URLSession RPC 启动/观察/控制权/停止、不同 profile 隔离、老后端降级、失败提醒、迟到结果、RPC 重连重新签发 viewer、同 RPC 的观察身份复用、票据地址与代理前缀校验。真实 WKWebView 测试完成 RFB 3.8 握手并读取解码后的 canvas 像素；分别验证只读、本人接管、交还后的键盘和鼠标按钮 RFB 输入，测试的画面是合成色块，不是真实 Xfce。显示层另覆盖握手超时、旧回调隔离、禁止画布拖动窗口和离线模块完整性。

实际 NSHostingView 布局回归确认：放大时聊天宽度为 0、电脑占满 800 pt；恢复原分栏及 510 pt 窄区布局后，电脑 NSView 身份不变，仅创建一次。原生应用 UI 检查确认入口、启动、接管/交还、分栏/放大、profile 切换、主窗口关闭的释放行为。模拟服务端检查确认主窗口关闭后 lease 为 agent、桌面仍运行、观看连接已关闭。窄聊天区的快捷键提示原先挤成逐字竖排，已改为紧凑分行布局，并在真实界面检查修复结果。

`./script/build_and_run.sh --verify`：签名 Debug 构建及启动通过。另以同一开发证书完成 Xcode Release 构建；两种产物含本地 noVNC 及许可证。日志分别在 `/tmp/hermes-mac-build.log`、`/tmp/hermes-bot-screen-release-build.log`，完整测试日志在 `/tmp/hermes-bot-screen-tests.log`。

通过用户已有登录连接当前 Linux 服务，默认 profile 的 `display.status` 返回可用且组件已安装。实际启动 Xfce，观看到面板、桌面与应用 dock；接管/交还的服务端状态正常，停止操作经过确认并返回「电脑已停止」。验收启动的桌面均已交还并停止，未向模型发送测试消息、安装远端软件或改变浏览器配置。

真实输入验收限制：原生自动化工具的鼠标操作可以触发远端悬停提示，但未观察到菜单/终端打开或键盘快捷键执行。已补 WebKit 原生首次点击、键盘焦点和非窗口拖动区域处理。另在临时真实 WKWebView 程序中复现：NSEvent 合成的可信 mousedown 可以带 `buttons=0`，导致 noVNC 发出的按钮掩码为 0；这与现象吻合，但不能认定私有自动化驱动采用相同方法。包装层对具有明确 `button` 的零掩码 mousedown 做兼容处理，不改 vendor；正常按钮、零掩码按钮和键盘输入均通过 WebKit/RFB 的只读/接管/交还边界测试。

修复后在同一真实服务复验：点击 Xfce Applications 菜单成功打开，选择 Terminal Emulator 并按 Enter 成功启动终端；键盘输入 `echo` 测试命令并执行，观察到输出，随后输入 `exit` 关闭终端、交还并停止桌面。因此基本真实点击、字母/空格输入和 Enter 已确认，不能再以仅悬停的早期结果描述最终版本。

剩余输入边界：自动化工具输入下划线或 Shift+minus 时符号未到达终端，不能据此认定物理键盘正常或异常；特殊符号、中文输入法、登录/2FA、剪贴板及 Agent 交还后的继续执行尚未完整实测。真实服务未报告 git SHA，不声称其与参考 revision 相同。

### 2026-10-14 只读桌面的鼠标处理修复

只读观看此前只设置 noVNC `viewOnly`：它禁止 RFB 输入发送，但仍保留本地 mousemove、坐标/定时器处理与远端自定义光标。真实 WKWebView 回归在修改前确认，120 次只读 mousemove 仍触发 120 次 noVNC `_handleMouseMove`，且 canvas 的计算 cursor 值为 `none`（由 noVNC 管理光标）。这证明“没有接管”不等于“本地鼠标不经过查看器”。

包装层改为只读时使用系统默认箭头、关闭 noVNC 的点击聚焦，并在捕获阶段截断鼠标/滚轮/触摸事件；CSS 同时关闭画布的 pointer hit testing 和 noVNC 的独立 fallback cursor。服务端确认本人接管后恢复交互，交还或重建观看连接后恢复只读模式。不修改 vendor、帧解码或桌面连接协议。

修改后同一真实 WKWebView 测试通过：只读 120 次移动对应 0 次 noVNC 鼠标处理；接管后恢复为 120 次；交还后的移动不再增加计数。既有键盘、鼠标按钮、零掩码按下兼容、RFB 握手与 canvas 像素检查同时通过。这是处理路径回归，不能当成物理鼠标端到端延迟的毫秒测量。

完整回归仍为 81 项（80 通过、1 项 opt-in live test 跳过、0 失败）；Debug 签名构建/启动通过，已恢复当前真实服务的只读桌面。界面检查确认画面仍显示、未接管，观看态鼠标经过 Applications 和 Terminal 区域不触发远端悬停/菜单操作。没有改变远端桌面的运行状态。测试日志在 `/tmp/hermes-watch-hover-regression.log`。

### 2026-10-15 同 profile 多会话并发与列表状态

发送互斥改为按 `(service, profile, storedID)` 管理；尚无持久 ID 的新建请求按导航实例隔离。同 profile 的其他生成中或待确认会话不再阻止发送，同一会话提交期间仍禁止重复提交。profile 级模型切换继续等待该 profile 的任务结束。会话列表显示呼吸小蓝点（启用系统减少动态效果时静态显示），结果未知显示“待确认”，完成后移除标识。

`./script/test.sh`：96 项测试，95 项通过、1 项 opt-in 真实服务测试跳过、0 失败。新增回归覆盖同 profile 的流式回答/草稿/未读隔离、待确认会话隔离、普通提交与补充消息提交期间的独立锁、重复发送防护、并行新建时迟到响应的选择与草稿保护，以及列表状态的 Observation 更新和跨服务/profile 隔离。

`./script/build_and_run.sh --verify`：签名 Debug 构建和应用启动通过。测试日志为 `/tmp/hermes-concurrent-sessions-tests.log`。本次未向真实模型发送测试消息；列表状态经过状态与观察回归，尚未进行真实并发回答的界面验收。

同日补充：列表中已完成未读的会话使用橘黄色边框，打开会话清除；生成中继续使用呼吸小蓝点。复用现有 `unread` 状态，并新增列表状态回归验证后台完成、已读清除、新回答与前台完成。完整测试更新为 97 项（96 通过、1 项 opt-in live test 跳过、0 失败）；签名 Debug 构建和启动通过。日志为 `/tmp/hermes-unread-border-tests.log`。未进行真实未读边框的界面验收。

## 可选真实服务测试

只有显式设置服务环境变量才运行 live test。先在应用设置中完成官方登录，下面的常规命令复用该服务在 Keychain 中保存的凭据。聊天模式会在选定服务创建两个测试会话并调用模型，可能产生费用：

```sh
HERMES_LIVE_SERVER='<自行填写已授权服务地址>' HERMES_LIVE_CHAT=1 swift test --filter LiveConnectionTests
```

省略 `HERMES_LIVE_CHAT=1` 时只验证已有凭据的连接和读取。测试另提供 `HERMES_LIVE_AUTH_URL_FILE` 辅助入口：指定临时文件时执行新的 PKCE 登录，将授权 URL 写入文件供受控验证工具处理；常规命令无需设置。密码由官方登录页面输入，不传到命令或源码。测试留下标题为 `HermesMac · connection test A` 和 `HermesMac · connection test B` 的两条聊天，保留供核对，不自动删除。再次运行聊天测试会新建会话。

## 可执行清单

记录 macOS/Xcode 版本、Hermes revision、服务运行平台、模型/provider、网络方式、每项结果和复现步骤。先按 [SETUP.md](SETUP.md) 启动本机服务，再在 Linux 重复服务相关项。

- [ ] 设置本机地址与正确 token，可加载 profiles；错误 token 显示认证失败。重启服务并更换 token 后，用新 token 可连接。
- [ ] Linux 非 loopback 配置官方 basic 或 OAuth provider，状态广告 `native_pkce`。系统浏览器登录返回应用，能加载 profiles。取消登录、错误密码、过期 refresh token 能再次登录。
- [ ] access token 到期后下一次受保护 REST 操作可刷新；WebSocket 断开重连能重新取得票据。日志、截图和 bug 报告不得附凭据。
- [ ] 在 CLI 为 A、B 产生历史，应用各自列表仅显示对应 profile。搜索、新建、右键重命名、加载更多和更早消息正确。
- [ ] 打开 CLI 历史并继续聊天，用户消息与流式答案显示，代码块可横向滚动且复制结果准确；停止按钮只停止当前会话。
- [ ] A 输入草稿，切 B 输入另一草稿，再切回 A：草稿与最后会话分别恢复。退出重开后继续保持。
- [ ] A 发送长任务，立即切 B 并发送；两边可以同时生成；在同一 profile 再开两个会话也可并发发送，会话列表分别显示呼吸小蓝点，完成后各自清除标识。当前会话运行中可发送引导或“完成后发送”。返回 A 时回复完整且未串到 B。
- [ ] A 在后台触发需要批准的工具，角色栏提示；点击 A 进入相应会话。明确拒绝、批准各试一次，B 的审批与内容不受影响，不自动批准。
- [ ] A 后台完成显示未读完成提示及会话列表橘黄色边框，查看 A 后清除；B 消息和草稿不变。
- [ ] 生成中断开网络：已显示内容保留，提示断线/结果未知。恢复网络后查询并恢复任务，客户端不会自动再次提交用户消息。
- [ ] 重启真实服务，确认后台任务是否仍存在由服务端决定；应用恢复已有历史或显示只读原因。没有重复用户消息或悬空“生成中”状态。
- [ ] 在 CLI 删除 profile 后重连，列表更新；已打开会话提示该 profile 已删除。不可恢复的历史能阅读但不能发送。
- [ ] 未知事件不崩溃；未知请求显示不支持，不提交批准。此项可先通过 mock，再用受控服务 fixture 检查。
- [ ] A 生成时更换服务地址，旧服务任务继续由服务端管理；旧事件不进入新服务，切回原地址能找回草稿。
- [ ] 中文拼音/五笔等 IME 组词时 Enter 只确认候选；已提交文字后 Enter 发送，Shift+Enter 换行。粘贴多行、长文本和连续切换输入法均无丢字或误发送。
- [ ] ⌘N、⌘[ / ⌘]、⇧⌘R、⌘, 有效。缩到最小窗口及放大后栏宽、输入框、审批按钮可用；系统深浅色文字与状态可辨认。
- [ ] 空闲时观察 Activity Monitor 和网络，没有持续高频请求；长输出流式更新可交互，不阻塞角色切换。

不满足项应保留截图/脱敏日志及复现步骤，并标明是客户端、服务能力还是模型/provider 限制。正式分发的签名、公证和升级机制不在当前本地构建验收范围内。

另已通过原生窗口检查：真实服务连接后显示 4 个 profile 与会话列表，打开 `HermesMac · connection test B` 能看到用户消息及 `HERMES_MAC_B_OK` 回复。Keychain 的同步调用已移到后台任务，系统权限等待不阻塞主窗口。真实中文输入法、深色外观和实际危险工具审批仍需人工验收。


## 2026-10-14 内存审计复核

本次核对了 `MEMORY_LEAK_AUDIT_REPORT.md` 并修正未经验证的泄漏推断。修复 WebKit 消息处理器和客户端断开回调的引用环，增加客户端析构清理、RPC 取消、20 个会话的缓存软上限，以及滚动配置调度合并。

- `./script/test.sh --filter StateTests`：初步状态测试通过。
- `./script/test.sh`：最终全套 86 项，0 失败，1 项真实服务测试按默认配置跳过。包括真实 WKWebView/noVNC、客户端释放、延迟 RPC 取消／迟到响应、会话淘汰与重新恢复，以及需处理状态保护。
- `./script/build_and_run.sh --build`：Debug 应用构建成功，使用现有本地签名身份。
- `git diff --check`：通过。

尚未执行 Instruments 的 Leaks/Allocations、真实服务长期内存测量或人工连续开关窗口验收。普通 VStack 的长会话峰值仍是需要测量的性能风险；保留已有避免动态高度／底部锚定卡死的布局策略。

建议人工验收：连续打开关闭电脑视图 20 次；访问超过 20 个历史会话并返回被淘汰的会话；在后台生成、待审批及断线结果未知时重复切换，确认状态仍可恢复。缓存上限是软上限，需处理状态可能使会话总数暂时超过 20。

## 2026-10-14 项目结构与可扩展性复核

核对 `PROJECT_STRUCTURE_AND_EXTENSIBILITY_REPORT.md`，区分实际风险与未来功能规划。移除全局滚动方法交换及私有 KVC；草稿改为独立字符串持久化，旧聚合状态自动迁移，输入热路径只写当前草稿；聊天/模型/能力协商请求集中为类型化 RPC 输入，模型目录读取、错误与版本失效逻辑抽离到 `ModelCatalogStore`。

- `./script/test.sh`：最终 90 项，0 失败，1 项真实服务测试按默认配置跳过。新增 4 项迁移、逐条写入及模型乱序/重置/切换竞态回归；更新现有滚动测试，验证无关 NSScrollView 不受影响，以及 SwiftUI modifier 实际设置透明背景和 overlay 样式。
- `./script/build_and_run.sh --build`：Debug 应用构建成功，使用现有本地签名身份。新增 Swift 文件已通过 `script/generate_project.py` 纳入 Xcode 工程。
- `git diff --check`：通过。

尚未执行本轮真实服务或人工界面外观验收。建议人工检查：深浅色下聊天、会话列表和代码块滚动条；设置窗口背景；长草稿输入后退出重开；模型刷新期间切换会话或重连。滚动条不再强制隐藏系统私有 track layer，hover/拖动时的原生轨道外观由 AppKit 管理。

本次未新增独立多窗口、离线历史数据库、Canvas/音视频协议或通用消息插件系统；这些属于功能演进。AppStore 仍承担会话和连接协调，本次完成模型目录领域的拆分而非整个应用架构重写。

## 2026-10-16：开发版标识、图标与单实例

- Debug 使用 `com.hermes.mac.dev` / `HermesMacDev`，显示名 Hermes Dev，图标为带橙色 DEV 角标的 AppIconDev；Release 保留 `com.hermes.mac` / HermesMac / AppIcon。凭据组件允许这两个标识，继续要求调用方与组件使用同一签名证书。
- Info.plist 禁止同版多实例；应用在初始化 AppStore 前获取按用户、bundle ID 隔离的非阻塞文件锁，重复启动唤起原进程并退出。锁由内核随进程退出释放，不删除锁文件以避免竞争。启动脚本只重启开发版，普通启动不再使用 `open -n`。
- `HERMES_TEST_VENV=/tmp/hermes-instance-py314 ./script/test.sh`：107 项，106 通过、1 项 opt-in live test 跳过、0 失败，包含同版锁竞争、两版锁共存、锁释放与获取失败回归。日志 `/tmp/hermes-single-instance-tests.log`。系统默认 Python 3.15 环境的 aiohttp 导入失败，本次使用独立 Python 3.14 环境验证。
- `./script/build_and_run.sh --verify`：Debug 签名构建及启动通过。Release 使用现有本地证书完成构建；日志 `/tmp/hermes-single-instance-release.log`。检查两版实际 Info.plist 的标识、可执行文件名、图标名、单实例开关与图标资源均正确。
- 同时运行 Debug 与 Release 后，分别直接启动第二个可执行文件以验证绕过 Launch Services 的情形：第二个进程均以 0 退出，原 PID 保持不变，两版各一个进程。Release 验收通过命令行临时将 serviceAddress 指向 loopback 关闭端口，不修改已保存的服务地址、不向真实模型发送消息。
- Computer Use 检查开发版窗口可见；重复打开后主窗口可见且开发版 PID 不变。开发版图标原图已视觉检查，未单独验收系统通知中的图标。

## 2026-10-18：长中文表格布局与流式更新

- 表格缓存当前单元格的 Markdown 解析结果及尺寸，流式后缀更新复用已完成单元格，字号改变时重新测量。缓存仅保留当前表格内容。
- 用具有明确行高的 VStack/HStack 替换横向 ScrollView 内的 Grid，并提供明确滚动区域高度，减少嵌套滚动时的自适应布局计算；保留横向滚动、文本选择及列对齐。
- 新增回归覆盖缓存复用／字号失效、长中文换行与文字高度，以及聊天滚动区域内 24 次流式更新和宽度变化；后者本机约 0.13 秒。这是自动布局回归用时，未测量真实会话滚动帧率。
- `HERMES_TEST_VENV=/tmp/hermes-instance-py314 ./script/test.sh`：110 项，0 失败，1 项 opt-in live test 跳过。日志 `/tmp/hermes-table-full-tests.log`。默认 Python 环境的 aiohttp 无法导入 web，沿用已存在的 Python 3.14 测试环境。
- `./script/build_and_run.sh --build`：Debug 签名构建成功。`git diff --check` 通过。
- 尚未人工验收截图中原始会话的滚动体验；建议在开发版复查该表格的横向／纵向滚动、流式生成、文本选择及字号调整。
