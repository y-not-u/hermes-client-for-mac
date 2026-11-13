# 验证与人工验收

### 2026-11-12 profile 自定义 emoji 图标

侧边栏 avatar 与聊天顶部 avatar 支持本机 emoji 图标：右键「设置图标…」打开选择器，可从 48 个常用 emoji 中点选，也可直接输入或粘贴任意 emoji（只取第一个字形），另有「使用默认」／右键「恢复默认图标」回到首字母渐变图标。`/api/profiles` 没有图标字段，图标按 `(服务, profile 名)` 存在 `LocalState` 的 `ServiceState.profileIcons`（UserDefaults），不写回服务端；服务地址变化或换服务时互不影响。设置 emoji 后 avatar 背景改为该 profile 调色板的淡色底，避免彩色 emoji 与饱和渐变冲突。

- 消息行 `MessageRowView` 新增 `profileEmoji` 参与 `Equatable` 比较，否则改图标后已渲染的历史消息头像不会刷新（第 24 条性能改动后行会被跳过重算）。
- 菜单项到 popover 之间延迟 60ms 再呈现，避免菜单关闭与 popover 同一次 runloop 冲突。
- 新增 `Tests/HermesMacTests/StateTests.swift` 中的 `testProfileIconPersistsLocallyAndFallsBackToInitial`（重载后仍保留、多字形输入只留一个、清除后回到默认）。
- 安装 Xcode 26.6 (17F113) 后复验（2026-11-12）：`./script/test.sh` 166 项，1 项 opt-in live test 跳过，0 失败；单跑上述用例通过（0.005 秒）。`./script/build_and_run.sh --build` Debug 构建通过，`DerivedData/Build/Products/Debug/HermesMac.app` 验签为 `HermesMac Local Development`，`codesign --verify --deep --strict` 通过，二进制 `x86_64 arm64`。
- 顺带修复 `script/setup_local_signing.sh` 在 macOS 自带 bash 3.2 下的 `set -u` 报错（空数组 `"${signing_keychain_args[@]}"` 被判为未绑定变量），改用 `${arr[@]+"${arr[@]}"}` 写法。
- 界面（右键菜单、popover 定位、emoji 缩放）仍未做人工验收，需要在实际服务上打开侧边栏与聊天顶部头像确认。

### 2026-11-12 流式回复期间的 CPU 占用

用户反馈回复流式输出时 CPU 占用升到约 30%。定位方式：临时在 Debug 构建里加了一个隐藏的探针入口（`HermesMac --stream-probe`，在 NSWindow 中托管真实 `ChatView`，按固定节奏注入合成 delta，用 `getrusage` 统计进程 CPU），测量后已全部删除，不留探针代码。

- 主要开销来自每收到一个 delta 就重绘整条转录：`MessageRowView` 原先没有 `Equatable`，没有闭包稳定的行也会重新求值；消息行里的 Markdown 分块（每行 `Text` + AttributedString + 悬停探针）随之全部重排。探针实测单次 delta 的 CPU 成本随转录长度增长：0 条历史约 17ms，8 条约 29ms，24 条约 75ms，60 条约 187ms。
- 改动一：`MessageRowView` 改为 `Equatable`，手写比较消息、工具调用、profile 与运行状态，忽略 `store` 和 `previewImage` 闭包，调用处加 `.equatable()`。
- 改动二：`Conversation` 将连续 delta 最多每 100ms 合并提交一次；首个片段立即提交，已处理的消息和状态事件及快照、切换会话等操作先提交缓冲文本，未知事件不触发提交。
- 固定负载对比：临时 Debug 探针以相同的 24 条合成历史、50ms 间隔和 200 个 delta 驱动真实聊天视图。33.3ms 提交间隔耗 CPU 4.687 秒、平均 46.9%；100ms 间隔耗 CPU 2.568 秒、平均 25.6%。两次均生成 1890 字，耗时约 10 秒。这是单次合成窗口测量，并非真实服务或 HEAD 基线。探针代码已删除。
- **未验证项**：没有取得 HEAD 的可比基线。用 `git worktree` 在独立目录构建 HEAD 对照版时冷编译超过 30 分钟被中止，因此上面只有同一份代码内部的对照数字，不能作为「相对修复前提升多少」的结论。
- 新增 `Tests/HermesMacTests/StreamingCoalescingTests.swift`（涵盖突发合并、未知事件、定时冲刷、完成/错误/工具/快照边界、interim 顺序及离开会话冲刷）。2026-11-12 在 Xcode 26.6 下已执行：9 项全部通过（随 `./script/test.sh` 全量 166 项跑通）。
- 目前只做了 `swift build`（Debug，应用目标）编译验证，未做界面人工验收，也未在真实服务上观察流式占用的变化。

### 2026-11-06 审批请求系统通知

新审批请求触发 macOS 通知，展示 profile 名称和审批说明（空说明使用打开应用处理审批的提示），前台也允许横幅和提示音。复用启动时的通知授权；回复完成通知仍只在后台触发。恢复会话快照中的待审批请求也接入通知，同一缓存会话内按请求 ID 去重，重复帧或断线恢复不会反复提醒。

`./script/test.sh`：155 项，1 项 opt-in live test 跳过，0 失败。新增状态回归覆盖前台、后台、快照恢复去重；现有跨 profile WebSocket 审批集成测试增加通知断言。`./script/build_and_run.sh --build` Debug 构建及 `git diff --check` 通过。日志 `/tmp/hermes-approval-notification-tests.log`。未进行真实 macOS 通知横幅及声音的人工验收；实际展示取决于系统通知授权和通知设置。

### 2026-11-06 会话列表边框状态

回答完成且未读的会话改用蓝色边框，打开后清除；存在待审批请求的会话显示橘黄色边框，优先于生成中、待确认及未读状态，审批结束后恢复对应状态。补充问题请求不作为审批请求处理。

`./script/test.sh`：154 项，1 项 opt-in live test 跳过，0 失败；新增回归覆盖审批请求及结束的 Observation 更新、状态优先级和后台回答完成。`./script/build_and_run.sh --build` Debug 构建通过，`git diff --check` 通过。尚未进行真实服务边框的界面验收。测试日志 `/tmp/hermes-session-border-tests.log`。

### 2026-11-03 更新卡片布局精简

删除更新来源和安装确认的说明，将「自动检查更新」与「检查更新…」置于同一行。`./script/build_and_run.sh --verify` 构建及启动通过；原生设置界面和截图确认控件同排、说明已移除。未改变更新逻辑。

## 2026-11-03 应用更新

- 集成固定版本 Sparkle 2.10.1，菜单与设置提供手动检查和自动检查开关；只在打包的正式版启动。默认每日检查，安装需确认，禁止静默自动安装。
- Xcode Debug、Release 通用构建通过；Debug 启动及原生设置卡片布局、版本显示和禁用状态已检查。最初自签名构建因 library validation 的不同 Team ID 错误启动失败，使用 `SelfSigned.entitlements` 对主应用关闭该项验证后启动通过；保留 Hardened Runtime 和 Sparkle 更新签名校验，未来换 Apple Developer ID 应移除该例外。
- `HERMES_TEST_VENV=/tmp/hermes-mac-test-venv ./script/test.sh`：149 项，1 项 opt-in live test 跳过，0 失败。新增 3 项配置检查覆盖正式/开发 bundle 隔离、无效 feed/key/build 及版本展示。日志 `/tmp/hermes-updater-final-tests.log`。
- `python3 script/test_prepare_update.py`：8 项通过（含多个 subtests），覆盖稳定 tag、不可变下载地址、签名/大小/版本检查、密钥清理及现有公钥不允许自动换钥匙覆盖 CI。`python3 script/test_ci_signing.py`：5 项通过。
- 实际 Release ZIP 经 `prepare_update.py` 生成 appcast，再用 Sparkle 官方 `sign_update --verify` 分别验证 ZIP 和 feed。嵌套代码签名验证通过。临时工具创建的隔离应用通过 Sparkle 检查本地签名 feed，接受 build 2；篡改版本后的 feed 被拒绝（`SUSparkleErrorDomain 1000`，improperly signed）。日志 `/tmp/hermes-update-probe.log`。
- 另用独立 bundle ID 的临时自签名应用验证完整升级：通过标准对话框选择 Install Update、Install and Relaunch，完成本地下载、签名验证、解压、替换旧 bundle，并在新版启动后验证 `CFBundleVersion=2`。测试应用和临时文件已清理。日志 `/tmp/hermes-update-install.log`。未替换用户 `/Applications/HermesMac.app`，未向真实服务器发送测试聊天或修改会话。
- `SPARKLE_PRIVATE_KEY` 已配置到 `y-not-u/hermes-client-for-mac` Actions Secrets，公钥在 Info.plist，原私钥保存在本机 Keychain 的 `com.hermes.mac.updates` account；临时导出已删除。实际更新私钥没有进入源码、日志或安装包。
- Bash 语法、工作流 YAML 解析和 `git diff --check` 通过。Git 的 `safe.bareRepository=explicit` 曾阻止 Xcode 解析包缓存，构建脚本已加入仅对子进程生效的兼容，不改全局配置。更改尚未提交/推送，也未创建 tag 或 GitHub Release；真实 GitHub 下载和正式 Hermes 连续版本升级仍需在首次发布后验收。

## 2026-11-03 固定自签名发布身份

- main/tag/手动发布改为从 Actions Secrets 导入固定 `.p12` 身份，按证书 SHA-1 指纹签名；缺少 secrets 时失败，PR 仅使用临时证书验证且不上传应用产物。
- `python3 script/test_ci_signing.py`：5 项通过。使用临时测试证书和模拟的 security/sudo，覆盖两次发布选择相同身份、缺少 secret、密码错误、身份不可用、无发布 secrets 的 PR 分支，以及临时证书文件清理；没有导出或上传用户私钥，也没有改动本机钥匙串。
- `HERMES_TEST_VENV=/tmp/hermes-mac-test-venv ./script/test.sh`：146 项，1 项 opt-in live test 跳过，0 失败。首次使用另一临时 Python 3.15 环境时 aiohttp 导入失败，换用已有可用环境后通过。日志 `/tmp/hermes-stable-signing-tests.log`。
- Bash 语法、工作流 YAML 解析、`git diff --check` 通过。已将本机现有 Hermes 签名身份按证书指纹单独导出为加密 PKCS#12，并配置到 `y-not-u/hermes-client-for-mac` 的两个 Actions Secrets；导出密码随机生成，临时导出文件和密码文件已删除，原钥匙串身份保留。`gh secret list` 已确认两个名称存在。尚未推送工作流修改或运行真实 GitHub Actions；固定签名连续升级后的本地网络授权保留仍需实机验收。用户已确认重新开启本地网络权限后，当前正式版恢复连接。

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

### 2026-10-18 设置认证入口简化

移除手动 Session Token 输入、显隐和覆盖保存入口，测试连接与重连沿用按服务地址保存的 Keychain 凭据；保留旧凭据读取兼容。官方账号登录的“清除”按钮改为“注销”，同步调整提示和部署说明。

`./script/build_and_run.sh --build`：Debug 构建通过。`./script/test.sh`：117 项测试，116 通过、1 项 opt-in 真实服务测试跳过、0 失败。默认临时 Python 环境的 aiohttp 导入异常，改用独立 `HERMES_TEST_VENV` 重跑通过。未进行真实服务登录/注销或设置窗口的人工界面验收。

### 2026-10-18 生成中追加保持输出

普通追加改用 `session.steer`，保留当前回答的流式归属；不再调用会取消当前模型请求的 `session.redirect`。明确拒绝或不支持 steer 时使用 `prompt.submit(queued=true)`，断线或未知结果不重发。状态显示“已提交补充，等待执行边界”，实际采用时间由服务端决定。

`HERMES_TEST_VENV=/tmp/hermes-supplement-test-venv ./script/test.sh`：118 项测试，117 通过、1 项 opt-in 真实服务测试跳过、0 失败。回归覆盖追加后继续输出、提交等待期间继续输出、连续追加、明确拒绝后的排队、完成边界竞态、断线不重发和跨会话隔离。默认临时 aiohttp 环境导入失败，使用独立临时环境验证。`./script/build_and_run.sh --build` 与 `--verify`：Debug 构建及启动进程检查通过。日志在 `/tmp/hermes-supplement-full.log`。本次未进行真实服务聊天或人工界面复测。

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
- [ ] 让 agent 调用 `clarify`（例如要求它在两种部署目标间确认）：当前会话出现澄清卡片，单选、多选、开放题各答一次，提交后卡片消失且回复继续；不答时 agent 停在同一处等待，不会拿到 `undelivered` 自行猜测。
- [ ] 澄清卡片只答一部分时「确认并继续」不可用；「取消本轮提问」后 agent 收到全部跳过并继续，卡片消失。
- [ ] 澄清卡片停留时切换会话或断线重连，重新打开该会话卡片与已选答案恢复；服务端超时撤回（`request.cancel`）后卡片自动消失。
- [ ] 澄清与审批同时存在时互不干扰：取消澄清不关闭审批卡片，反之亦然。
- [ ] A 后台完成显示未读完成提示及会话列表橘黄色边框，查看 A 后清除；B 消息和草稿不变。
- [ ] 生成中断开网络：已显示内容保留，提示断线/结果未知。恢复网络后查询并恢复任务，客户端不会自动再次提交用户消息。
- [ ] 重启真实服务，确认后台任务是否仍存在由服务端决定；应用恢复已有历史或显示只读原因。没有重复用户消息或悬空“生成中”状态。
- [ ] 在 CLI 删除 profile 后重连，列表更新；已打开会话提示该 profile 已删除。不可恢复的历史能阅读但不能发送。
- [ ] 未知事件不崩溃；未知请求回 `-32601` 并提示不支持，不提交批准。`clarify`、`approval` 已有卡片，其余方法仍走该兜底。此项可先通过 mock，再用受控服务 fixture 检查。
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

## 2026-10-18：中文标点旁的 Markdown 加粗

- 正文与表格共用 `InlineMarkdown`，兼容 `**适合怎么放：**若……`、`**“大场面”**的……` 等中文标点边界；解析时临时补充字母边界，解析后删除，不在显示／复制内容中留下占位符。
- 新增 6 项回归，覆盖截图中的中文段落、多处加粗、嵌套斜体／链接、代码与转义星号、链接目标、流式补全及表格单元格；同时检查原有正常 Markdown 的解析结果保持一致。
- `HERMES_TEST_VENV=/tmp/hermes-instance-py314 ./script/test.sh`：116 项，0 失败，1 项 opt-in live test 跳过。日志 `/tmp/hermes-inline-full-tests.log`。
- `./script/build_and_run.sh --build`：Debug 签名构建成功，随后启动开发版并确认进程运行。`git diff --check` 通过。
- 未人工复查截图原始会话；建议打开该回复检查中文引号／冒号附近的加粗及复制文本。

## 2026-10-18：Markdown 链接悬停光标

- 正文与表格的蓝色链接悬停时设置 `NSCursor.pointingHand`，保留 SwiftUI Text 的选择、链接样式及点击行为。仅含链接的文字启用悬停桥接。
- 通过原生 NSTextField 的公开辅助功能字符几何信息识别链接区域，缓存与当前文本／布局对应的字符矩形；换行链接逐字命中，普通文字与行尾空白不属于链接区域。
- 新增原生 NSHostingView 回归，检查多行中文链接的每个字符、周边普通文字、界外位置，以及文字更新后的失效。
- `HERMES_TEST_VENV=/tmp/hermes-instance-py314 ./script/test.sh`：117 项，0 失败，1 项 opt-in live test 跳过。日志 `/tmp/hermes-link-full-tests.log`。
- `./script/build_and_run.sh --build`：Debug 签名构建成功；随后重新启动开发版。`git diff --check` 通过。尚未在原始会话中人工移动鼠标验收。

## 2026-10-19：设置页模型配置（主模型与 Fallback 链）

- 设置新增「模型设置」标签，包含：主模型（全局默认）、Fallback 链（`fallback_providers` 有序链，可添加/移除/重排）。
- 主模型写 `POST /api/model/set`（body `{scope: "main", provider, model, profile}`），读用不带 `session_id` 的 `model.options`。Fallback 链走 `GET /api/config?profile=…` 读取 `fallback_providers`，写 `PUT /api/config`（body `{profile, config: {fallback_providers: [{provider, model}]}}`，空数组清除），与官方 `FallbackModelsField` 实现一致。读取/写入失败保留原值并提示，不静默降级。
- `./script/test.sh`：135 项，134 通过、1 项 opt-in live test 跳过、0 失败。新增集成回归覆盖主模型/Fallback 设置与读取回读。`swift build` 通过。
- 未做真实验收：对照官方 `hermes_cli/web_routers/config_env.py`、`models.py` 与 `apps/desktop/src/app/settings/fallback-models-field.tsx` 源码实现：主模型使用 `POST /api/model/set`，Fallback 链使用 `GET/PUT /api/config`。建议在支持的服务上人工验证主模型与 Fallback 链是否生效。

## 2026-10-25 会话修改版本快照

归档报 HTTP 409 `client_upgrade_required` 的原因是客户端未发送新版后端要求的修改身份。归档、重命名和删除现先读取 `mutation-snapshot`，携带请求 ID、版本号及可用的 generation；快照路由 404/405 时兼容旧后端，其他快照错误中止写入。冲突不自动重发，保留本地会话状态。

- `HERMES_TEST_VENV=/tmp/hermes-session-mutation-venv ./script/test.sh`：139 项，138 通过、1 项 opt-in live test 跳过、0 失败。新增回归验证新版修改身份、旧版路由兼容、无效/失败快照阻止写入及冲突时不移除会话、不重发。
- `./script/build_and_run.sh --verify`：Debug 签名构建与启动进程检查通过。`git diff --check` 通过。
- 原临时 Python 环境的 Python 3.15 ensurepip 失败，使用 Python 3.14 创建独立临时测试环境后通过。日志：`/tmp/hermes-session-mutation-tests.log`、`/tmp/hermes-mac-build.log`。
- 未在真实服务修改用户会话；真实归档、删除、重命名仍需人工验收。


### 后续实机排查：airelay 归档仍返回 404

用户报告 airelay profile 所有会话归档失败。通过开发版 `SessionMutation` 统一日志确认，原报错会话的快照读取成功（`exists=true`、revision 0），随后的 PATCH 返回 HTTP 404 `not_found`。参考官方 `tests/gateway/test_multiplex_cold_profile_sidebar_mutation.py`，为 PATCH 的 query 同时补齐与 body 一致的 profile 后重建、启动，并在同一会话复测，仍返回 404；因此不能将缺少 query 认定为该故障的根因或声称已修复。会话仍保留在列表中。

诊断日志仅记录快照是否存在、revision、修改方法和 HTTP 状态，不含令牌、会话标题、消息或服务地址。`HERMES_TEST_VENV=/tmp/hermes-session-mutation-venv ./script/test.sh`：139 项、1 项 opt-in live test 跳过、0 失败；`./script/build_and_run.sh --verify` 构建与启动通过。尚需真实后端的 revision、启动方式与归档服务端日志，以区分快照数据库与 Gateway 写入路由/存储不一致等可能原因。日志在 `/tmp/hermes-archive-404-runtime.log`，测试日志在 `/tmp/hermes-archive-404-tests.log`。


### SSH 后端修复与真实归档验收

通过已授权的 `ssh hermes` 检查，服务端源码基于 `4d04303818b61bf3aa09278af48356315515965b`，独立 dashboard 转发修改到运行中的 Gateway。原报错会话来源为 `dashboard`，没有 chat/session 路由；`hermes_state_mutation_binding._history_sources()` 未包含此来源，`authorize_history()` 返回 False，随后 API 会话恢复因没有对应绑定而返回 `not_found`。补齐 PATCH query 的试验无效，已撤回客户端该项改动。

后端将 `dashboard` 纳入可做元数据修改的历史来源，保留登录用户、已有归属绑定及路由检查。真实会话只读验证：补丁前其对应登录的 `authorize_history=False`；补丁后 True，其他用户仍返回 `permission_denied`。运行正常的 `hermes gateway restart`，等待现有工作结束并完成服务恢复，没有使用强制中断参数。

从开发版界面重新归档原报错的 evoxt 会话成功：会话从列表消失；只读数据库验证 `archived=1`、`runtime_revision=1`，39 条消息保留。客户端另在归档/删除开始时清理上一条失败提示，避免成功后仍显示旧的 404。开发版已重建、启动，界面无旧错误。

- 客户端完整测试：139 项、138 通过、1 项 opt-in live test 跳过、0 失败。日志 `/tmp/hermes-archive-verified-tests.log`。
- 后端针对性回归：`tests/hermes_state/test_history_login_label.py` 18 项通过，含 dashboard 来源本人可修改、其他用户被拒绝；加上 HTTP/WS 修改协议的 2 项检查共 20 项通过。使用 PM 构建独立测试环境，通过官方 `scripts/run_tests.sh`，并以 `-k "not test_http_import_and_delete_keep_atomic_receipts"` 排除下述环境失败用例。日志 `/tmp/hermes-dashboard-history-focused-tests.log`。
- 扩展后端检查未全通过：HTTP import/delete 测试被真实 home I/O 防护阻止读取部署目录旁的 `manifest.json`；cold-import 集成测试因临时 Gateway 仍在准备依赖而未在启动时限内就绪。日志 `/tmp/hermes-dashboard-history-tests.log`；未放宽这些测试保护或调整真实用户配置。
- 部署的后端源码/测试补丁保存于 [patches/hermes-dashboard-history-control.patch](patches/hermes-dashboard-history-control.patch)，适用于上述后端基线；是当前机器本地兼容修复，尚未推送上游。

## 2026-11-03 输入框粘贴图片和文件

- `./script/test.sh`：146 项，145 通过、1 项 opt-in live test 跳过、0 失败。日志 `/tmp/hermes-paste-full.log`。
- 新增 `ComposerAttachmentTests` 7 项：原生粘贴与禁用编辑器、PNG/TIFF、普通文字不识别为附件、Finder 文件 URL 与文件夹拒绝、大小/数量限制、服务与角色隔离、纯附件发送、图片/文件上传先于 prompt、部分失败清理、上传期间新草稿隔离与原会话路由。
- 上传切换回归曾发现来源为新会话草稿的上传锁错误影响下一份新草稿；已将上传锁随创建完成的目标会话迁移，完整重跑通过。
- `./script/build_and_run.sh --build`：Debug 签名构建通过，日志 `/tmp/hermes-mac-build.log`。`git diff --check` 通过。
- 已启动隔离模拟服务窗口检查基本连接；完整 Finder→输入框的界面粘贴与缩略图布局未完成人工验收，不作为已验证项。未向真实服务上传或发送附件，模型视觉输入及真实文件读取仍需人工验收。
- 手动验收：复制截图后在输入框 ⌘V；从 Finder 复制图片及多个普通文件后粘贴；检查缩略图/名称与移除按钮；分别发送纯附件和文字加附件；等待生成结束后发送带附件草稿；切换会话后确认附件隔离。错误路径检查文件夹、超过 10 MB 文件与旧服务不支持附件方法时保留草稿。

## 2026-11-05 图片已上传但模型未收到

- 通过 `ssh hermes` 只读核对部署源码 revision `b200f5bc60e31588ba2cb60e288029c4a54ba5fa`：`gateway/session_images.py` 的 `image.attach_bytes` 只暂存图片，返回 `path` 与 `mime`；`gateway/session_ingress_media.py` 要求 `prompt.submit.attachments: [{path, mime}]` 才将字节纳入本轮输入。客户端此前沿用旧版会话暂挂语义，提交时漏了该字段。
- 客户端按上传响应的 `mime` 识别新版契约并携带图片引用；旧版无 `mime` 响应继续使用会话暂挂语义。新版提交前上传失败保留草稿，无需调用旧版 `image.detach`。
- 新增两项集成回归：两张图片的路径、MIME 和目标会话随 prompt 提交；新版暂存图片后的部分上传失败保留草稿且不发送 prompt。旧版附件测试继续验证不附加新版参数及失败时 detach。
- `./script/test.sh`：151 项，150 通过、1 项 opt-in live test 跳过、0 失败。日志 `/tmp/hermes-image-full.log`。初次针对性测试暴露测试自身的模拟请求序号计算错误，修正后完整套件通过。
- `./script/build_and_run.sh --verify`：Debug 签名构建、开发版启动与进程检查通过。`git diff --check` 通过。日志 `/tmp/hermes-image-build.log`、`/tmp/hermes-mac-build.log`。
- 本次未向真实模型发送测试图片；真实模型视觉回复仍待用户在 Hermes Dev 重新粘贴并发送验收。未修改或重启后端。

## 2026-11-05 主窗口缩放布局优化

- 主聊天／电脑分栏改用 SwiftUI `Layout` 接收尺寸提案并放置现有子视图；几何读取仅用于分隔线的拖动命中区域。调整窗口大小不再逐次调用聊天与电脑面板的内容构建闭包，电脑面板展开／还原仍保留 viewer 实例。
- 聊天底部位置改用 anchor preference 在独立覆盖层中解析；移除包住整个消息列表的 `GeometryReader`。仅在底部可见性变化时写入状态，保留非懒加载消息布局以避免图片加载导致历史估算高度循环。
- 新增真实 NSWindow 回归：电脑打开／关闭两种模式下连续改变宽高，面板内容构建次数保持不变；与 HEAD 旧分栏对照，旧实现同一组操作分别额外构建 14 次和 7 次，新实现均为 0。此数字是构建闭包调用次数，不是帧率或整体耗时测量。对照日志 `/tmp/hermes-resize-baseline.log`，修复后针对性日志 `/tmp/hermes-resize-focused.log`。
- 新增真实聊天窗口回归：初次定位底部，上翻后流式追加不抢回阅读位置，缩窄窗口后仍保持上翻状态，手动回到底部后继续跟随流式文字；原电脑展开、窄窗口和 viewer 实例保留测试通过。
- `./script/test.sh`：153 项，152 通过、1 项 opt-in live test 跳过、0 失败。日志 `/tmp/hermes-resize-full.log`。`./script/build_and_run.sh --verify`：Debug 签名构建、开发版启动与进程检查通过，构建日志 `/tmp/hermes-mac-build.log`。`git diff --check` 通过。
- 尚未对用户原始长会话做人工连续拖动或帧率采样；原生文本仍需随实际宽度重新换行。人工验收可在 Hermes Dev 连续拖动窗口边缘，再分别检查上翻阅读、正在生成回复及打开电脑时的缩放体验。
