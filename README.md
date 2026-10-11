# Hermes for Mac

macOS 14+ 原生 SwiftUI 客户端，用一个连接访问本机或局域网 Linux 上的 Hermes 服务。三栏界面提供 profile 切换、历史搜索与恢复、聊天流式输出、停止生成、工具详情和人工审批。

客户端不启动服务；profile、模型、工具和记忆继续通过 Hermes CLI 管理。不同 profile 可同时生成，同一 profile 同时只允许一个生成中的会话。切换角色不会停止原任务；后台完成和待审批状态显示在角色栏。

## 构建与运行

安装 Xcode（含 macOS SDK），并让 `xcode-select -p` 指向完整 Xcode。客户端没有第三方 Swift 依赖。

```sh
./script/setup_local_signing.sh # 本机首次运行，创建固定签名证书
./script/build_and_run.sh --build
./script/build_and_run.sh
./script/test.sh
```

本机 Debug 构建默认使用钥匙串中的 `HermesMac Local Development` 自签名证书，无需 Apple 开发者账号。首次设置证书或使用私钥时，系统可能要求授权；首次从旧的临时签名切换后，读取已有登录凭据也可能需要再次选择“始终允许”。保留同一证书及私钥，之后重新编译保持相同的应用身份。不要每次重建证书。可用 `HERMES_SIGNING_IDENTITY="证书名称"` 指定其他签名，或 `HERMES_SIGNING_IDENTITY=-` 临时构建（可能重复请求 Keychain 授权）。直接在 Xcode 中运行 Debug 也使用该本地证书。

GitHub Actions 在 push 到 `main`、向 `main` 提交 PR 或手动触发时运行模拟测试，构建 Release 的 Apple Silicon / Intel 通用应用，并上传 `HermesMac.zip` 与 SHA-256 校验文件。推送 `v*` tag 还会创建 GitHub Release。CI 使用临时签名，不需要开发者账号、证书或 Secrets；它未做 Developer ID 签名和公证，下载后首次运行可能需要在系统设置的“隐私与安全性”中允许打开。不同 CI 构建的签名身份会变化，升级时可能再次请求 Keychain 授权。

构建产物在 `DerivedData/Build/Products/Debug/HermesMac.app`，构建日志在 `/tmp/hermes-mac-build.log`。运行脚本会先关闭现有 HermesMac 进程。`--verify` 检查启动进程，`--debug` 启动 LLDB，`--logs` / `--telemetry` 查看日志。新增 Swift 文件后运行 `python3 script/generate_project.py` 更新 Xcode 工程。测试使用 SwiftPM 和本地 aiohttp 模拟服务；需要 Python 3，脚本会在 `/tmp/hermes-mac-test-venv` 自动安装 aiohttp 3.13.3（首次需要网络），可用 `HERMES_TEST_VENV` 更改测试环境路径。

## 连接

先按 [服务部署说明](docs/SETUP.md) 启动 Hermes，再打开应用设置（⌘,）：填写服务地址，本机填写 session token；Linux 服务点击“在系统浏览器登录”。“测试连接”检查 REST 状态接口，“保存并重新连接”还检查 WebSocket 和 JSON-RPC。

快捷键：Enter 发送、Shift+Enter 换行、⌘N 新会话、⌘[ / ⌘] 切换角色、⇧⌘R 重连。重命名位于会话右键菜单。点击待审批角色进入对应会话，审批需要明确选择，不会自动批准。

地址、profile 顺序、最后选中会话和输入草稿保存在 UserDefaults，并按服务隔离；凭据保存在 Keychain。历史保存在服务端，客户端不复制 Hermes 配置、记忆或数据库。修改服务地址会清空运行状态，不会中断旧服务上的任务。连接中断保留当前内容并尝试恢复；发送结果未知时不自动重发。

## 兼容与验证边界

源码契约参考固定为官方 Hermes revision [`c57331677d7fc46298a7159cf3a650853f0966c5`](https://github.com/NousResearch/hermes-agent/tree/c57331677d7fc46298a7159cf3a650853f0966c5)。10 项本地模拟测试通过；另在用户提供的 Hermes 0.21.5 局域网服务通过原生认证、历史恢复、两个 profiles 并行真实回复、草稿隔离、重命名和重连测试。真实服务仅广告版本号，不能据此认定运行上述 git revision。真实工具审批、中断、网络故障、服务重启与中文输入法仍需人工验收。详见 [协议约定](docs/PROTOCOL.md) 与 [验证记录](docs/VALIDATION.md)。

首版 Markdown 支持内联格式与可复制围栏代码块；不提供完整 Markdown 表格、图片附件或语法高亮。首版不包含 profile 创建和配置编辑、SSH、服务自动启动、语音、附件、文件浏览器、多服务同时连接，也不捆绑 Python、Hermes 或浏览器运行时。
