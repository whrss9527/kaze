<div align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Proxi icon">
  <h1>Proxi</h1>
  <p><strong>One switch for all your proxies</strong></p>
  <p>A proxy switch that lives in the macOS menu bar. Native Swift, glass design, free and open source.</p>
  <p>
    <a href="https://github.com/whrss9527/proxi/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/whrss9527/proxi?include_prereleases&label=release&color=2F6BEA"></a>
    <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&logoColor=white">
    <img alt="Liquid Glass" src="https://img.shields.io/badge/UI-Liquid%20Glass-7C6CFF">
    <a href="LICENSE"><img alt="GPL-3.0" src="https://img.shields.io/badge/license-GPL--3.0-2563EB"></a>
  </p>
  <p>
    <a href="https://github.com/whrss9527/proxi/releases/latest"><b>Download</b></a> ·
    <a href="CHANGELOG.md">Changelog</a> ·
    <a href="docs/automation.md">Automation</a> ·
    <a href="https://github.com/whrss9527/proxyswitch">Windows version</a> ·
    <a href="README.zh-CN.md">简体中文</a>
  </p>
</div>

### **Proxi** /ˈprɒk.si/

Say it out loud and it's still **proxy**.

Swap the **y** for an **i**: **y** is *why*, **i** is *I*.

One less "why", one more "I".

A proxy shouldn't be just a complicated networking tool. It should be a remote control that's truly in your hands: how you connect, where traffic goes and when it's on are all up to you.

**Proxi** is the proxy that's yours.

<p align="center"><img src="docs/hero.png" width="1000" alt="The Settings window, the menu bar panel and the network speed in the menu bar"></p>

The screenshots show the Chinese interface. Proxi is in English when your system language isn't Chinese, and you can pick the language under Settings → General → Language.

## Features

- **One-click switching**: the system proxy, environment variables, git and npm switch together; set up several profiles and change between them with a click.
- **Subscriptions that just work**: paste your provider's subscription URL, then pick nodes, test latency and route by rules, all from the panel.
- **The whole Mac, and your game console too**: enhanced mode sends Terminal and games through the proxy; LAN sharing and gateway mode let a PS5, Switch or phone use this Mac's connection.
- **Every connection in sight**: which app connected where, which rule matched and which node it used; when a site won't open, diagnose it with one click.
- **Scripts and AI**: control it from the command line, MCP and URL commands, and switch profiles automatically by Wi‑Fi.
- **Low maintenance**: profiles sync across your Macs with iCloud; new versions install with one click.
- **English or Chinese**: the interface follows your system language, or pick one under Settings → General.

## Install

Requires macOS 14 or later, on Intel or Apple silicon.

1. Download `Proxi-macos.zip` from [Releases](../../releases), unzip it and drag `Proxi.app` to Applications.
2. Double-click to open it. For opening versions that weren't notarized, see the [user guide](docs/guide.md#安装) (in Chinese).
3. When a new version comes out, click "Update" in the panel.

If you used ProxySwitch, updating from the old version in one click turns it into Proxi and keeps your settings; see [updating from ProxySwitch](docs/guide.md#从-proxyswitch-更新). The Windows version is [proxyswitch](https://github.com/whrss9527/proxyswitch).

## Getting started

| Action | Result |
| --- | --- |
| Left-click the menu bar icon | Opens the panel: the big switch, profiles, latency and one-click testing |
| Right-click (or Control-click) | A compact menu |
| ⌃⌥P | Turns the proxy on or off from anywhere (you can change it in Settings) |
| Settings → Nodes & Subscriptions | Paste your provider's subscription URL and the nodes appear in the panel |
| `proxi status`, `proxi node HK` in Terminal | Check and switch from the command line (install the command-line tool on the Automation page first) |

## Documentation

The documents are in Chinese for now.

- [User guide](docs/guide.md): installing and updating, every feature, the built-in node proxy, enhanced mode and gateway mode, LAN sharing, permissions and file locations
- [Automation](docs/automation.md): the command line, MCP, URL commands and the formats Proxi can import
- [Development guide](docs/development.md): building, code layout, CI and releases; signing and notarization are in [docs/signing.md](docs/signing.md)
- [Changelog](CHANGELOG.md)

## Support

Proxi is free and open source. If you find it useful, a ⭐ Star means a lot; you can also buy me a coffee with WeChat (the code is also in Settings → About).

<p align="center"><img src="Resources/donate-wechat.png" width="240" alt="WeChat tip code: buy me a coffee"></p>

## License

Copyright © 2026 吴彦祖

Proxi is free software released under the [GNU General Public License v3 (GPL-3.0)](LICENSE): you can use, study, modify and share it freely; when you distribute Proxi or a modified version, you must provide the source code under the same license.

The name "Proxi" and the Proxi icon aren't covered by the GPL (GPL-3.0 section 7(e)). You may use them to talk about Proxi or to share unmodified copies; when distributing a modified version, please use your own name and icon.

Contributions require accepting the contributor agreement in [CONTRIBUTING.md](CONTRIBUTING.md).

Versions 0.10.0 and earlier were released under the MIT license, which still applies to those versions.

---

<div align="center">
  <p><b>Also living in the menu bar</b></p>
  <a href="https://github.com/whrss9527/pop"><img src="https://raw.githubusercontent.com/whrss9527/whrss9527/master/assets/cards/pop.svg" width="30%" alt="Pop: long-press right-click, one swipe away"></a>
  <a href="https://github.com/whrss9527/meno"><img src="https://raw.githubusercontent.com/whrss9527/whrss9527/master/assets/cards/meno.svg" width="30%" alt="Meno: a quiet menu bar made of glass"></a>
  <a href="https://github.com/whrss9527/stox"><img src="https://raw.githubusercontent.com/whrss9527/whrss9527/master/assets/cards/stox.svg" width="30%" alt="Stox: quotes at a glance, gone in a click"></a>
</div>
