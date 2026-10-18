# 服务部署

## 固定官方版本

需要已有可用 Hermes 环境、模型凭据和至少一个 profile。协议对照 revision 为 `c57331677d7fc46298a7159cf3a650853f0966c5`。在独立源码目录安装，以免影响其他 Hermes 安装：

```sh
git clone https://github.com/NousResearch/hermes-agent.git hermes-agent-mac-backend
cd hermes-agent-mac-backend
git checkout c57331677d7fc46298a7159cf3a650853f0966c5
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e '.[web]'
hermes setup
```

该 revision 的 Python 范围为 3.11–3.14。模型/provider 若需要额外依赖，依官方 CLI 配置流程安装。已有 Hermes 配置可直接使用；不要复制其数据库到客户端。后续所有 `hermes` 命令都使用此虚拟环境中的命令。`hermes serve` 是无浏览器后端，跳过 dashboard 前端构建，因此纯原生客户端无需 Node 或 npm。

## 客户端认证

客户端通过浏览器完成官方登录，自动将凭据保存到 Keychain，不再提供手动输入 Session Token 的入口。本机或 Linux 新服务请配置下文的官方认证 provider，并确认服务支持 `native_pkce`。

已有 Keychain 凭据仍会按服务地址读取，包括旧版保存的 session token。仅支持 session token 的服务在没有可用已存凭据时，需要先配置官方认证再登录。

## Linux 官方认证与 native_pkce

在 Linux 使用同一 revision，按上面的虚拟环境步骤准备 Hermes。将下面设置合并进当前服务使用的 `config.yaml`（默认 `~/.hermes/config.yaml`），保留原有模型/profile 配置。官方内置 `basic` 是密码登录 provider，支持 native broker；不是 HTTP Basic header。

在激活虚拟环境的源码目录生成密码哈希，密码通过交互输入：

```sh
python -c 'from getpass import getpass; from plugins.dashboard_auth.basic import hash_password; print(hash_password(getpass("Dashboard password: ")))'
python -c 'import secrets; print(secrets.token_hex(32))'
```

将第一条输出写入 `password_hash`，第二条写入 `secret`：

```yaml
dashboard:
  basic_auth:
    username: hermes
    password_hash: "<第一条输出>"
    secret: "<第二条输出>"
```

确保 `basic` 未被 `plugins.disabled` 禁用；需要时运行 `hermes plugins enable basic`。固定 `secret` 让签发的凭据跨服务重启有效；省略它会使用每次启动的新随机 secret。保护配置文件权限。

```sh
hermes serve --host 0.0.0.0 --port 9119
```

在 Mac 设置 `http://<Linux 局域网 IP>:9119`，点击“在浏览器中登录”，在官方登录页面输入配置的用户名和密码，浏览器将回到 Mac 上临时监听的 `127.0.0.1` 回调地址。客户端使用 state、PKCE S256 换取 access / refresh token，并保存到 Keychain；REST 使用 Bearer token，WebSocket 先取 `/api/auth/ws-ticket` 票据。

HTTP 局域网直连不加密凭据和聊天。若网络不能充分信任，请在 Linux 前使用 HTTPS 反向代理及系统信任的证书，并将服务地址填写为 HTTPS；代理需支持 WebSocket Upgrade，按官方配置 `dashboard.public_url`。客户端沿用系统证书校验，不提供忽略证书错误选项。只开放必要网络范围的端口。

非 loopback 服务必须配置官方认证 provider；该 revision 的 `--insecure` 是弃用且无效的开关，不能用它绕过认证。也可使用官方 `hermes dashboard register` 配置 Nous OAuth，客户端仍走同一 native_pkce 流程。

## 排查

- “测试连接”只证明 `/api/status` 返回 JSON；真正连接还需要受保护 REST、WebSocket 和 `client.capabilities`。
- `/api/status` 的 `auth_required=true` 时需要原生登录；`auth_flows` 必须包含 `native_pkce`。缺少时升级到协议基线并配置 provider。
- 401：在设置中重新登录；仅支持 session token 的旧服务需先配置官方认证 provider。服务重启后 secret 变化会使登录凭据失效。
- HTTP 404、非 JSON 或 JSON-RPC 方法不支持：核对端口、反向代理前缀和 revision；客户端不会切换到其他协议。
- macOS 15+ 若出现 `Local network prohibited`，检查“系统设置 → 隐私与安全性 → 本地网络”是否允许 HermesMac，授权后退出并重开应用。终端可访问并不证明应用也有本地网络权限。
- 不可恢复历史会显示只读原因，可查阅内容并新建会话。断线后的发送结果未知时先查历史，再决定是否手动发送。

## 开发构建与 Keychain 授权

本地自签名应用的 Keychain 分区权限会绑定二进制 `cdhash`，仅固定签名证书无法避免每次重新编译后的授权弹窗。Xcode 构建会将独立的 `HermesCredentialHelper` 放入应用，由它读写 Keychain；普通界面修改不会改变这个组件的身份。组件会验证调用方的 bundle identifier（正式版 `com.hermes.mac` 或开发版 `com.hermes.mac.dev`）和签名证书，凭据只通过进程管道传递，不写入文件或日志。

第一次升级到凭据组件时，现有 Keychain 项目可能需要一次授权。系统弹窗中的申请方应为 `HermesCredentialHelper`，请选择“始终允许”。以后普通界面重编译不需要再次授权；修改凭据组件本身、更新编译工具链或更换签名证书仍可能需要重新授权。拒绝访问或钥匙串锁定时，应用会显示读取失败，保留已有凭据，解锁/授权后重新连接即可。

使用 `./script/build_and_run.sh` 或 Xcode 构建完整应用；`swift test` 用于测试，不应以未打包的 SwiftPM 可执行文件替代日常应用。
