# 应用更新

正式版通过 Sparkle 2.10.1 从 GitHub Releases 检查、下载并安装更新。Hermes 菜单有「检查更新…」，设置 → 偏好与显示 → 应用更新可手动检查或关闭自动检查。默认每天检查，安装需用户确认，不静默替换或重启。开发版和未打包的 SwiftPM 测试不会启动更新器。

首次需要手动安装包含更新器的正式版；旧版没有更新器，不能自动获得该功能。首次正式 Release 发布前，更新清单 URL 尚不存在，检查会显示获取失败；发布后才可正常检查。

## 签名与密钥

应用仍使用固定的 `HermesMac Local Development` 自签名身份，保持 `com.hermes.mac` 不变。Sparkle 另用独立 Ed25519 密钥验证更新包、更新清单及其中嵌入的更新说明，HTTPS 提供传输保护；更新包在解压前先验证签名。这不要求付费开发者账号，也不提供 Apple 公证。

自签名应用没有 Apple Team ID，macOS 的 Hardened Runtime library validation 会拒绝加载嵌入且重新签名的 Sparkle（实测启动时报 different Team IDs）。工程使用 `SelfSigned.entitlements` 对主应用关闭该项 library validation，保留 Hardened Runtime 及更新签名验证。以后改用 Apple Developer ID 时应清空 `CODE_SIGN_ENTITLEMENTS` 或移除该例外，恢复系统默认校验。

- `HermesMac/Info.plist` 中 `SUPublicEDKey` 是公开密钥，可以提交。
- 仓库 Actions Secret `SPARKLE_PRIVATE_KEY` 是私钥，只在 tag 发布的签名步骤注入。
- 原始私钥保存在本机 Keychain，account 为 `com.hermes.mac.updates`。不要丢失或随意重新生成：已有安装只信任原来的公钥。
- 固定应用签名的两个 `HERMES_SIGNING_P12_*` Secrets 仍然需要；详见 [签名设置](SETUP.md#无开发者账号的固定发布签名)。

一次性创建或恢复 CI 更新签名配置（先完成一次 Xcode 依赖解析）：

```sh
python3 script/setup_update_signing.py \
  --sparkle-bin DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
```

脚本复用该 account 的现有密钥，通过 `gh` 配置 Secret，将公钥写入 Info.plist，并删除临时私钥导出。Info.plist 已有公钥时，本机密钥缺失或不匹配会停止，不会自动换钥匙覆盖 CI。需保留并提交公钥修改。若更换电脑，可先从旧电脑用 Sparkle `generate_keys --account com.hermes.mac.updates -x <仓库外的备份路径>` 导出，妥善离线保存，在新电脑用同一工具的 `-f` 导入。私钥和私钥备份不得进入仓库或构建产物。

## 发布

1. 将功能、公钥和工作流修改提交并推送到 main，等待检查通过。
2. 创建递增的稳定版本 tag，例如 `v0.1.0`；格式必须为 `v主版本.次版本.修订号`，不接受预发布后缀。
3. 推送 tag 后，CI 从 tag 写入 `CFBundleShortVersionString`，从 `GITHUB_RUN_NUMBER` 写入递增的 `CFBundleVersion`。
4. CI 构建、验证嵌套签名、打包应用，再用 Sparkle 官方工具生成并验证带签名的 `appcast.xml`，随 ZIP 和 SHA-256 文件一起上传到 GitHub Release。

更新清单固定地址：`https://github.com/y-not-u/hermes-client-for-mac/releases/latest/download/appcast.xml`。清单内的 ZIP 地址使用对应 tag 的不可变下载路径。首次实现保留一个最新稳定更新，使用完整 ZIP，不生成 delta。后续如提高最低 macOS 版本或需要维护旧系统更新分支，应改为保留多版本 appcast。

main/PR 构建用于验证，不发布更新清单。main 构建的展示版本为工程默认的 `0.1.0`；用户安装以 tag Release 为准。不要回退版本 tag 或重置工作流 build number；Sparkle 通过内部 build number 比较新旧。发布前不要手动修改生成的已签名 appcast，改动后必须重新签名。

## 验证

```sh
python3 script/test_prepare_update.py
./script/test.sh
./script/build_and_run.sh --build
```

若全局 Git 配置为 `safe.bareRepository=explicit`，Xcode 的 SwiftPM 缓存可能无法读取。构建脚本会仅在本次子进程内允许 bare 缓存，不修改全局 Git 配置。

发布两个测试版本后验证：旧正式版能提示新版本、显示更新记录、下载并安装、重启后版本号更新，且服务配置、Keychain 凭据及本地网络权限可用。自动更新的退出路径沿用应用现有的桌面控制释放流程；进行中的服务端任务仍在服务器继续，安装前宜等待当前回复结束。

只有自签名身份时，固定证书能消除每次更换身份的因素，但仍无法保证 macOS 永远保留本地网络授权；遇到 `Local network prohibited` 仍需在系统设置中重新开启。签名、版本或网络错误应在 Sparkle 对话框查看，不能通过关闭签名校验解决。

参考：[Sparkle 配置](https://sparkle-project.org/documentation/)、[发布更新](https://sparkle-project.org/documentation/publishing/)、[安全配置](https://sparkle-project.org/documentation/customization/)。
