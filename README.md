# ProxySwitch for Mac

macOS 菜单栏里的代理开关：一键切换系统代理、环境变量、git 和 npm 的代理设置，多套配置随时切换。原生 Swift 写成，界面是毛玻璃风格，在 macOS 26 上会用系统的 Liquid Glass。

Windows 版在 [proxyswitch](https://github.com/whrss9527/proxyswitch)，两边功能各自演进。

<p align="center"><img src="docs/panel.jpg" width="360" alt="菜单栏面板"></p>
<p align="center"><img src="docs/settings.jpg" width="720" alt="设置窗口"></p>

## 功能

- **内置节点代理**：填一个机场的订阅地址，节点就出现在面板里，可以选节点、自动选择延迟最低的、一键测速；支持全局代理和按规则分流，规则可以直接用 [johnshall 的小火箭规则](https://github.com/johnshall/Shadowrocket-ADBlock-Rules-Forever)（黑名单、白名单、去广告等预设）或任何小火箭 / Surge / Clash 格式的规则地址。不用再装 Clash 或小火箭。
- **局域网共享**：打开后 PS5、Switch、手机等同一局域网里的设备把这台 Mac 当代理服务器（`Mac 的 IP:7892`），就能享受和本机一样的网络：本机走节点它们就走同样的节点和规则，本机用公司代理它们就转发给公司代理，本机没开代理就经这台 Mac 直连，切换配置时几秒内跟着变。默认只允许局域网网段里的设备，也可以只允许指定的 IP。
- **网址诊断**：某个网站打不开时，填上网址，从这台 Mac 或 PS5 等设备的视角把链路走一遍——本机 / 共享状态、DNS、直连、经代理（从内核日志里抓命中的规则和走的节点）、节点延迟——给一句结论和修复按钮（开启节点代理、让这个域名走节点、自动选择节点）。`open "proxyswitch://diagnose?url=https://youtube.com"` 也能直接发起。
- **菜单栏面板**：点图标弹出，大开关、配置列表和每个配置的延迟、复制在当前终端里用代理的命令、一键测速、进设置。右键或 Control + 点击是简洁菜单。
- **多套配置**：HTTP / SOCKS5 / PAC 三种。每套可以选生效范围：系统代理、环境变量、git、npm。
- **系统代理**：读取和监听用 SystemConfiguration，别的程序（Clash、Surge、公司脚本）改了代理会立刻反映在图标上，可以一键保存成配置。写入用 `networksetup`。
- **环境变量**：写到 launchd（`launchctl setenv`），之后新开的终端和程序都能读到；已经打开的终端用面板里复制的 `export` 命令。
- **测速与健康检查**：经代理实际访问测速地址测延迟（PAC 由系统执行，和浏览器一致）；开启期间定期检查代理端口，连不上时提醒。
- **自动检测**：找出本机正在运行的代理软件监听的端口，确认能用后一键添加。
- **全局快捷键**：默认 ⌃⌥P 开关代理，可以在设置里录制新的。
- **登录时启动**：系统设置的「登录项」里可以看到和关闭。
- **命令**：`open proxyswitch://toggle`、`proxyswitch://on`、`proxyswitch://off`、`proxyswitch://use?name=配置名`、`proxyswitch://share`（`share/on`、`share/off`）、`proxyswitch://settings`、`proxyswitch://update`，可以接快捷指令和脚本。
- **iCloud 同步**：打开后代理配置和设置通过 iCloud 云盘（`iCloud 云盘/ProxySwitch/config.json`）在多台 Mac 之间同步，几秒内生效；另一台 Mac 开启时可以选用 iCloud 的、用本机的或合并，两边同时改以改动时间晚的为准。
- **检查更新与一键更新**：启动后和每 6 小时检查一次 GitHub 上的新版本（可以关掉），有新版本时通知（通知上直接有「立即更新」按钮），面板里出现更新条。点一下「更新」就会下载本机芯片的精简包、比对 SHA-256、替换 `ProxySwitch.app` 并自动重新启动，不用去下载页。内置代理在运行时经它下载，失败再试系统代理和直连。直接在下载文件夹里打开的程序会被装进「应用程序」，旧的那份移到废纸篓。

## 内置节点代理

1. 设置 → 节点与订阅，粘上机场给的订阅地址点「添加」。内核会下载解析，配置列表里自动多一条「节点代理」。
2. 面板里开关「节点代理」就是开关它：开启后系统代理指向 `127.0.0.1:7890`（HTTP 和 SOCKS 同一个端口）。节点卡片里可以选节点、自动选择、测速、切换全局 / 规则。
3. 「自定义规则」可以让某个域名（含子域名）或 IP / 网段固定走节点、直连或拦截，排在预设规则前面，全局模式下也生效，改了立刻生效。规则分流的来源可以选内置的「国内直连」、johnshall 的几套小火箭规则，或者填自己的规则地址。小火箭 `.conf` 里的 `[Rule]` 段会转成内核规则：`DOMAIN-SUFFIX`、`DOMAIN-KEYWORD`、`IP-CIDR`、`GEOIP`、`RULE-SET`（下载后内联）、`FINAL` 都支持，`USER-AGENT`、`URL-REGEX` 这类内核不支持的会跳过；`Proxy` 类策略走面板里选中的节点。
4. 内核是 [mihomo](https://github.com/MetaCubeX/mihomo)（Clash Meta，GPL-3.0），以独立程序的形式打包在 `ProxySwitch.app/Contents/MacOS/mihomo`，默认只监听本机端口（开了局域网共享才多一个给局域网设备的入口），配置在 `~/Library/Application Support/ProxySwitch/core/`。GeoIP 数据来自 [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat)。
5. 不支持 TUN 模式：只有走系统代理（或环境变量）的程序会经过它，和小火箭 Mac 版的默认行为一样。

## 局域网共享（PS5 / Switch）

1. 设置 → 局域网共享，打开「允许局域网里的设备经这台 Mac 上网」。页面上会显示要在设备上填的地址，比如 `192.168.1.5 : 7892`。
2. PS5：设置 → 网络 → 设置 → 设置互联网连接 → 选中正在用的网络 → 高级设置 → 代理服务器 → 「使用」，填 Mac 的 IP 和端口。Switch：设置 → 互联网 → 互联网设置 → 选中网络 → 更改设置 → 代理服务器设置。手机、电脑在 Wi‑Fi 的手动代理里填同样的地址。
3. 之后设备的流量跟着本机走：本机开着「节点代理」，设备就用同样的节点和分流规则（全局 / 规则跟着切）；本机用公司代理或者别的代理软件，就转发给它；本机没开代理，就经这台 Mac 直连。面板里切换配置，设备几秒内跟着变。PAC 脚本没法转发，这时设备直连并在页面上提示。
4. 共享由内置的内核完成：它在 `0.0.0.0:7892` 多开一个入口，用 mihomo 的 `lan-allowed-ips` 只放行局域网网段（10.x、172.16–31.x、192.168.x）；页面上可以改成只允许指定的 IP 或网段。公共 Wi‑Fi 上建议关掉。没有订阅也能开共享，只为共享运行时本机的 7890 端口不占用。
5. 页面上能看到正在使用的设备（来源 IP、连接数、流量、最近访问的站点和走的出口）和「最近的连接」（域名 → 节点 / 直连，命中的规则），还可以从本机经共享端口自测。建议在路由器里给 Mac 固定 IP，不然 IP 变了设备就连不上。开着 macOS 防火墙时第一次会询问是否允许 mihomo 接受传入连接，要允许。
6. 两个限制要知道：PS5 的代理设置只对系统流量（联网测试、PSN、商店）和浏览器生效，YouTube、Netflix 这类应用可能用自己的网络栈、不走代理——打开应用时「最近的连接」里没有出现它的域名就是这种情况，用 PS5 的浏览器打开同一个网站可以对照；游戏联机的 UDP 流量也不经 HTTP 代理。设备自己解析 DNS 被污染、拿着假 IP 来连的情况内核会处理：开着域名嗅探，从 TLS 握手里取回域名再分流。
7. 共享是本机的设置（放在 `state.json`），不跟着 iCloud 同步；右键菜单和 `open proxyswitch://share` 也能开关。

## 安装

1. 在 [Releases](../../releases) 下载 `ProxySwitch-macos.zip`（通用包，Intel 和 Apple 芯片都能用；`-arm64` / `-x86_64` 结尾的是只含一种芯片的精简包，小一半），解压后把 `ProxySwitch.app` 拖到「应用程序」。
2. 程序没有 Apple 开发者签名，第一次打开会被系统拦下：在 `ProxySwitch.app` 上右键 → 打开 → 再点「打开」；或者在终端运行 `xattr -dr com.apple.quarantine /Applications/ProxySwitch.app`。
3. 需要 macOS 14 或更新版本。
4. 之后的版本在程序里一键更新：有新版本时面板里会出现更新条，点「更新」就行，也可以在「关于」页或通知上点「立即更新」。如果程序是在下载文件夹里直接打开的（系统会把它放在只读的临时位置运行），更新时会自动装进「应用程序」，第一次可能会问能否访问「下载」文件夹（用来把旧的那份移到废纸篓）。

## 权限说明

- 修改系统代理需要**管理员账户**。标准账户会弹出系统的授权对话框，输入一次管理员密码。
- iCloud 同步用的是 iCloud 云盘里的普通文件夹（没有开发者签名拿不到 iCloud 的 entitlement），第一次开启时系统可能会询问是否允许访问 iCloud 云盘。
- 全局快捷键用 Carbon 的热键接口，不需要辅助功能权限。
- 通知需要在第一次弹出时允许。

## 文件位置

配置、状态和日志都在 `~/Library/Application Support/ProxySwitch/`：`config.json`、`state.json`、`proxyswitch.log`。诊断页里可以直接打开这个目录。

## 开发

需要 Xcode 16 或更新版本（用 Xcode 26 编译才有 Liquid Glass）。

```bash
swift build                          # 编译
swift test                           # 单元测试（纯逻辑：命令生成、状态解析、配置读写……）
VERSION=0.1.0 Scripts/build-app.sh   # 组装通用二进制的 dist/ProxySwitch.app 和 zip，ad-hoc 签名
```

代码结构：

| 目录 | 内容 |
| --- | --- |
| `Sources/ProxySwitch/App` | 入口、`AppState`（配置、状态、开关逻辑） |
| `Sources/ProxySwitch/Models` | 配置、系统代理快照、networksetup 命令的生成 |
| `Sources/ProxySwitch/System` | 系统代理、环境变量、git / npm、测速、快捷键、登录项、通知、URL 命令、更新、iCloud 文件、内核进程与 API、规则转换、局域网地址 |
| `Sources/ProxySwitch/UI` | 菜单栏图标与面板、设置窗口各页、毛玻璃样式、快捷键录制 |
| `Tests` | XCTest |
| `Scripts/build-app.sh` | 组装 .app（下载 mihomo 合成通用二进制、GeoIP 数据库）、签名、打 zip |
| `Resources` | Info.plist、图标 |

推送代码时 GitHub Actions 会在 macOS 上编译、测试、打包并启动一次截图，然后用本地 HTTP 服务器假装发布一个 9.9.9 版本，走一遍下载、校验、替换、重新启动的完整更新流程；推送 `v*` 标签会自动打包并发布 Release。

本机调试更新流程时可以把环境变量 `PROXYSWITCH_UPDATE_URL` 指向一个返回 GitHub releases 格式 JSON 的地址；调试 iCloud 同步时可以用 `PROXYSWITCH_SYNC_DIR` 把同步文件夹指到任意目录（见 `.github/workflows/ci.yml` 里的做法）。

## 许可证

[MIT](LICENSE)
