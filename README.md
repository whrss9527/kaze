<div align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Proxi 图标">
  <h1>Proxi</h1>
  <p><strong>一个开关，管好所有代理</strong></p>
  <p>住在 macOS 菜单栏里的代理开关。原生 Swift，玻璃质感，开源免费。</p>
  <p>
    <a href="https://github.com/whrss9527/proxi/releases/latest"><img alt="最新版本" src="https://img.shields.io/github/v/release/whrss9527/proxi?include_prereleases&label=release&color=2F6BEA"></a>
    <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&logoColor=white">
    <img alt="Liquid Glass" src="https://img.shields.io/badge/UI-Liquid%20Glass-7C6CFF">
    <a href="LICENSE"><img alt="GPL-3.0" src="https://img.shields.io/badge/license-GPL--3.0-2563EB"></a>
  </p>
  <p>
    <a href="https://github.com/whrss9527/proxi/releases/latest"><b>下载</b></a> ·
    <a href="CHANGELOG.md">更新日志</a> ·
    <a href="docs/automation.md">自动化</a> ·
    <a href="https://github.com/whrss9527/proxyswitch">Windows 版</a>
  </p>
</div>

### **Proxi** /ˈprɒk.si/

念起来还是 **proxy**。

把 **y** 换成 **i**：**y** 是 *why*，**i** 是 *I*。

少一个“为什么”，多一个“我”。

代理不应该只是一个复杂的网络工具，而应该是一个真正交到你手里的遥控器：怎么连、走哪里、什么时候开关，都由你自己决定。

**Proxi**，就是属于你的代理。

<p align="center"><img src="docs/hero.png" width="1000" alt="设置窗口、菜单栏面板和菜单栏里的网速"></p>

## 特性

- **一键切换**：系统代理、环境变量、git、npm 一起开关；配好几套，点一下就换。
- **订阅直接用**：填上机场的订阅地址，选节点、测速、按规则分流，面板里都能搞定。
- **整台 Mac，连同游戏机**：增强模式让终端和游戏也走代理；局域网共享和网关模式让 PS5、Switch、手机跟着这台 Mac 走。
- **每条连接都看得见**：哪个程序连了哪里、命中哪条规则、走了哪个节点，一清二楚；网站打不开时，一键诊断。
- **交给脚本和 AI**：命令行、MCP、URL 命令都能控制，还能按 Wi‑Fi 自动切换配置。
- **省心**：配置用 iCloud 在几台 Mac 之间同步；有新版本，点一下就更新好。

## 安装

需要 macOS 14 或更新版本，Intel 和 Apple 芯片都能用。

1. 在 [Releases](../../releases) 下载 `Proxi-macos.zip`，解压后把 `Proxi.app` 拖到「应用程序」。
2. 双击打开。没经过公证的版本第一次打开的办法见[使用指南](docs/guide.md#安装)。
3. 以后有新版本，面板里点「更新」就行。

以前用 ProxySwitch 的，在旧版本里一键更新就会变成 Proxi，配置都在，见[从 ProxySwitch 更新](docs/guide.md#从-proxyswitch-更新)。Windows 版在 [proxyswitch](https://github.com/whrss9527/proxyswitch)。

## 上手

| 操作 | 效果 |
| --- | --- |
| 左键点菜单栏图标 | 打开面板：大开关、配置列表、延迟、一键测速 |
| 右键（或 Control + 点击） | 简洁菜单 |
| ⌃⌥P | 在任何地方开关代理（可以在设置里换） |
| 设置 → 节点与订阅 | 粘上机场的订阅地址，节点就出现在面板里 |
| 终端里 `proxi status`、`proxi node 香港` | 用命令行查看和切换（先在「自动化」页装上命令行工具） |

## 文档

- [使用指南](docs/guide.md)：安装与更新、全部功能、内置节点代理、增强模式和网关模式、局域网共享、权限与文件位置
- [自动化](docs/automation.md)：命令行、MCP、URL 命令、能导入的格式
- [开发指南](docs/development.md)：构建、代码结构、CI 与发版；签名和公证见 [docs/signing.md](docs/signing.md)
- [更新日志](CHANGELOG.md)

## 支持

Proxi 免费开源。觉得好用的话，点个 ⭐ Star 就是很大的鼓励；也可以微信扫一扫请我喝杯咖啡（程序里「设置 → 关于」也有这张码）。

<p align="center"><img src="Resources/donate-wechat.png" width="240" alt="微信赞赏码：请我喝杯咖啡"></p>

## 许可证

Copyright © 2026 吴彦祖

Proxi 是自由软件，以 [GNU 通用公共许可证第 3 版（GPL-3.0）](LICENSE) 发布：可以自由使用、研究、修改和分享；分发 Proxi 或修改后的版本时，需要以同样的许可证提供源代码。

「Proxi」这个名字和 Proxi 的图标不在 GPL 授权范围内（GPL-3.0 第 7 条 e 项）。介绍 Proxi、分享未经修改的副本时可以使用；分发修改后的版本时，请换用自己的名字和图标。

贡献需接受 [CONTRIBUTING.md](CONTRIBUTING.md) 里的贡献者协议。

0.10.0 及以前的版本以 MIT 许可证发布，这些版本仍然适用 MIT 许可证。

---

<div align="center">
  <p><b>同样住在菜单栏里</b></p>
  <a href="https://github.com/whrss9527/pop"><img src="https://raw.githubusercontent.com/whrss9527/whrss9527/master/assets/cards/pop.svg" width="30%" alt="Pop：长按右键，一划即达"></a>
  <a href="https://github.com/whrss9527/meno"><img src="https://raw.githubusercontent.com/whrss9527/whrss9527/master/assets/cards/meno.svg" width="30%" alt="Meno：安静的菜单栏，由玻璃打造"></a>
  <a href="https://github.com/whrss9527/stox"><img src="https://raw.githubusercontent.com/whrss9527/whrss9527/master/assets/cards/stox.svg" width="30%" alt="Stox：一眼看盘，一键隐身"></a>
</div>
