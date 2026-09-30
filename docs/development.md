# Proxi 开发指南

[← 回到 README](../README.zh-CN.md)

## 开发

需要 Xcode 16 或更新版本（用 Xcode 26 编译才有 Liquid Glass）。

```bash
swift build                          # 编译
swift test                           # 单元测试（纯逻辑：命令生成、状态解析、配置读写……）
VERSION=0.1.0 Scripts/build-app.sh   # 组装通用二进制的 dist/Proxi.app 和 zip，ad-hoc 签名
```

设置 `CODESIGN_IDENTITY="Developer ID Application: …"` 时用开发者证书签名；发布时的签名和公证怎么配置见 [docs/signing.md](signing.md)。

代码结构：

| 目录 | 内容 |
| --- | --- |
| `Sources/Proxi/App` | 入口、`AppState`（配置、状态、开关逻辑、导入）、`Engine`（内核、节点、策略组、规则集、连接与流量、服务检测）、本机控制接口、命令行、按网络自动切换 |
| `Sources/Proxi/Models` | 配置、系统代理快照、networksetup 命令的生成、策略组、规则集与规则库、自定义规则、DNS 与 Hosts、手动节点、节点筛选、流量统计、自动化 |
| `Sources/Proxi/System` | 系统代理、环境变量、git / npm、测速、快捷键、登录项、通知、URL 命令、更新、iCloud 文件、内核进程与 API、内核配置生成与补丁、规则转换与下载、YAML、配置导入导出、控制接口的套接字与 MCP、二维码、出口 IP、局域网地址 |
| `Sources/Proxi/UI` | 菜单栏图标与面板、设置窗口各页（节点、分流规则、连接、自动化、高级……）、导入预览、毛玻璃样式、快捷键录制 |
| `Tests` | XCTest |
| `Scripts/build-app.sh` | 组装 .app（下载 mihomo 合成通用二进制、GeoIP 数据库）、签名、打 zip |
| `Scripts/import-certificate.sh`、`Scripts/notarize.sh` | 发布时导入 Developer ID 证书、提交苹果公证并钉上票据 |
| `Scripts/check-localization.py` | 检查英文和简体中文的界面文字齐不齐、有没有漏掉 `L()` 的中文 |
| `Resources` | Info.plist、权限声明、图标，英文（`en.lproj`）和简体中文（`zh-Hans.lproj`）的界面文字 |

### 界面语言

界面有英文和简体中文。代码里显示给用户的文字写中文原文，经 `L("中文原文", 参数…)` 翻译（见 `Sources/Proxi/App/AppLanguage.swift`）；中文原文就是 `Resources/en.lproj/Localizable.strings` 和 `Resources/zh-Hans.lproj/Localizable.strings` 里的键，`Scripts/build-app.sh` 把它们拷进程序。参数用 `%@` 占位，译文里可以用 `%1$@`、`%2$@` 调换顺序。日志、内核配置里的名字（「节点」「自动选择」这类，界面上经 `CoreConfigBuilder.displayName` 换成界面语言）和按中文匹配的关键词不翻译，行尾标 `// l10n-ignore`。

加了或改了文字，两个表都要改，再跑一遍 `python3 Scripts/check-localization.py`，CI 每次推送都会跑。界面语言跟着系统，设置 → 通用 → 界面语言可以单独选（写在 Proxi 自己偏好设置的 `AppleLanguages` 里，重新启动生效）。不改系统语言试英文界面：

```bash
defaults write com.whrss9527.proxyswitch AppleLanguages -array en   # 删掉这个键就是跟随系统
```

推送代码时 GitHub Actions 会检查界面文字的翻译，在 macOS 上编译、测试、打包并启动一次截图（中文界面，再用英文界面启动几次截图，确认界面、命令行和跟随系统都是英文），然后用本地 HTTP 服务器假装发布一个 9.9.9 版本，走一遍下载、校验、替换、重新启动的完整更新流程，再用一张临时的自签名证书把签名流程走一遍；推送 `v*` 标签会自动打包并发布 Release，配了证书时顺便签名和公证。

本仓库分支开的合并请求（草稿除外）测试全部通过后自动合并进 main。合并后，如果 `CHANGELOG.md` 最上面的版本还没有标签，就自动打上 `v版本号` 的标签、打包并发布 Release；所以要发版时，在 `CHANGELOG.md` 最上面加一节新版本就行。测试期间 main 有了新提交时不会自动合并，把 main 合进分支再推一次即可。

本机调试更新流程时可以把环境变量 `PROXI_UPDATE_URL` 指向一个返回 GitHub releases 格式 JSON 的地址；调试 iCloud 同步时可以用 `PROXI_SYNC_DIR` 把同步文件夹指到任意目录（见 `.github/workflows/ci.yml` 里的做法）。
