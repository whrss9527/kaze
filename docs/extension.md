# 代理引擎（扩展）

> 本功能仅供学习、研究网络技术及合法的开发调试使用，不得用于任何违反所在国家或地区法律法规的用途。
>
> 1. 开发者不提供任何代理服务、服务器或订阅，也不对第三方提供的内容负责；
> 2. 使用者应自行确认其使用行为符合当地法律法规，并独立承担因使用本功能产生的全部责任；
> 3. 请在下载后 24 小时内自行评估是否继续使用；如不同意上述条款，请勿开启本功能。
>
> 开启即表示你已阅读并同意以上条款。

> This feature is provided only for learning, for research into network technology, and for lawful development and debugging. It must not be used for any purpose that violates the laws or regulations of your country or region.
>
> 1. The developer provides no proxy service, servers or subscriptions, and is not responsible for any content provided by third parties.
> 2. You are responsible for making sure your use complies with local laws and regulations, and you bear full responsibility for all consequences of using this feature.
> 3. Please decide within 24 hours of downloading whether to continue using it. If you do not agree to these terms, do not enable this feature.
>
> Enabling it means you have read and agree to these terms.

## 是什么

Proxi 本身只切换代理设置。「代理引擎」是一个可选扩展：一个在本机运行的代理引擎（基于开源的 [mihomo](https://github.com/MetaCubeX/mihomo) 内核），作为单独的程序 `Proxi Engine.app` 提供，不包含在 Proxi 里。

- 默认关闭。在 Proxi 的「设置 → 扩展」里打开开关，看完上面的说明、勾选「我已阅读并同意」并点「开启」后才会下载。说明的内容改过以后要重新同意。
- 关闭时 Proxi 不下载、不检查更新、不访问任何和它有关的地址，菜单、面板、命令行和 AI 助手的工具里都没有它（`proxi status --json` 里只报告 `"extension": {"enabled": false}`）。

## 下载了什么、放在哪里

| 什么 | 从哪里来 | 怎么校验 | 放在哪里 |
| --- | --- | --- | --- |
| `Proxi-Engine-<版本>.zip` | Proxi 同一个版本的 GitHub 发布 | `SHA256SUMS.txt` 里的校验和；bundle identifier（`com.whrss9527.proxyswitch.engine`）、版本和 Proxi 一样；Proxi 是开发者签名的时，签名的 Team ID 也要和 Proxi 一样 | `~/Library/Application Support/Proxi/Extensions/Proxi Engine.app` |
| 内核 mihomo v1.19.31（Apple 芯片用 `darwin-arm64`，Intel 用 `darwin-amd64-compatible`） | 上游项目的正式发布 | 压缩包和解压后的程序的 SHA-256 都写死在代码里（`Sources/ProxiEngine/System/CoreDownload.swift`） | `~/Library/Application Support/Proxi/engine/bin/mihomo` |
| GeoIP 数据库 `Country.mmdb` | 固定的一次发布（不跟着「最新」走） | SHA-256 写死在代码里 | `~/Library/Application Support/Proxi/engine/bin/Country.mmdb` |

代理引擎的设置和数据在 `~/Library/Application Support/Proxi/engine/`。代理引擎的「内核」页可以重新下载或删除内核；Proxi 扩展页的「关闭并移除」删掉下载的程序，数据留着。

代理引擎和 Proxi 同一个版本、一起发布。Proxi 更新后，扩展开着时会下载同一个版本的代理引擎替换旧的。

放在 Proxi 的数据目录里（而不是「应用程序」）是因为不需要管理员密码就能装、能换；增强模式和网关模式要的特权助手不经过 `SMAppService`，而是用管理员授权把程序和内核复制到 `/Library/PrivilegedHelperTools`（root 所有、只有 root 能写），所以对程序放在哪里没有要求。

## 和 Proxi 怎么配合

- 代理引擎运行时把状态（端口、内核在不在运行）写在 `engine/status.json`。Proxi 按它在配置列表最前面放一条「代理引擎」配置，指向 `127.0.0.1:<端口>`，用 Proxi 原来的开关开启：系统代理、终端环境变量、git、npm 怎么设，和其他配置一样。开启这条配置时代理引擎没在运行，Proxi 会先启动它、等内核起来。
- 这条配置不写进 `config.json`，也不经 iCloud 同步到别的 Mac。
- 订阅、节点、策略组、分流规则、规则集、网址检测、增强模式（TUN）、网关模式、局域网共享、配置导入、连接和流量都在代理引擎自己的菜单栏图标和设置窗口里。
- 关闭扩展时，正在用「代理引擎」配置的话先关掉代理、恢复系统设置，再退出代理引擎，配置列表里的那条也去掉。

## 特权助手

增强模式和网关模式要以 root 运行内核，第一次用时会请你输入管理员密码装一个特权助手（`/Library/PrivilegedHelperTools/com.whrss9527.proxyswitch.helper`）。助手把内核复制到只有 root 能写的位置，复制后和每次启动内核前都核对它的 SHA-256，只运行写死在代码里的那几个版本。只听装它的那个用户的请求。

扩展没开时用不上它；以前的版本装过的话，Proxi 会提示可以移除（「设置 → 通用」里也能移除）。

## 从以前的版本更新过来

以前的版本（0.12 及以前）里代理引擎是 Proxi 的一部分。更新后第一次启动：

- 订阅、节点、规则等设置和 `core/`、`imports/`、操作记录都原样挪到 `engine/`，另存一份 `config-0.12-backup.json` 和 `state-0.12-backup.json`，不删任何东西；
- 上次开着的是代理引擎那条配置时，先关掉代理（不然系统代理会指向一个没人监听的端口）；
- 有这些数据时问一次要不要开启扩展：开启后下载安装代理引擎，用原来的数据启动，内核起来后把原来开着的配置开回来；暂不开启的话数据留着，以后随时可以在「设置 → 扩展」里开启。

## 内核的许可证

mihomo 以 GPL-3.0 发布，源代码见其项目主页。
