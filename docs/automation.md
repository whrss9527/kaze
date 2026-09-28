# 自动化：命令行、AI 助手、快捷指令和配置导入

ProxySwitch 在本机开了一个控制接口（Unix 套接字 `~/Library/Application Support/ProxySwitch/control.sock`，只有你自己的账户能连）。命令行工具、MCP 服务器（给 AI 助手用）和 URL 命令都经它操作正在运行的 ProxySwitch，用的是同一套工具。

能做到哪一步由设置 →「自动化」里的**权限**决定：

| 权限 | 能做什么 |
| --- | --- |
| 关闭 | 接口不开，命令行和 AI 助手都连不上 |
| 只能查看 | 查看状态、节点、规则、连接、流量、日志，诊断网址，导出配置，预览导入 |
| 日常操作 | 另外可以开关代理、切换节点 / 策略组 / 模式、测速、服务检测、更新订阅和规则、断开连接、开关局域网共享 |
| 完全控制（默认） | 另外可以加删规则、订阅、节点、规则集、策略组，导入配置，撤销 |

改配置的操作都记在「自动化」页的**操作记录**里，可以撤销（命令行 `proxyswitch undo`，AI 助手用 `undo` 工具）。设置窗口里的导入也记在这里。

## 命令行

在「自动化」页点「安装命令行工具」，会在 `/usr/local/bin/proxyswitch` 放一个小脚本（要输一次管理员密码）；不装也可以直接运行 `/Applications/ProxySwitch.app/Contents/MacOS/ProxySwitch <命令>`。ProxySwitch 没在运行时会自动在后台打开。

```bash
proxyswitch status                      # 代理现在的状态
proxyswitch on 节点代理                  # 开启某个配置（不写就开上次用的）
proxyswitch off
proxyswitch nodes 香港                   # 列出名字里有「香港」的节点和延迟
proxyswitch node 香港 02                 # 切换节点（名字可以只写一部分，唯一匹配就行）
proxyswitch node auto                   # 自动选择
proxyswitch group 流媒体 日本 01          # 给策略组选成员
proxyswitch mode global                 # 全局代理；rule 是规则分流
proxyswitch test 香港                    # 测名字里有「香港」的节点的延迟
proxyswitch services                    # 检测 ChatGPT、Netflix 等服务经现在的节点能不能用
proxyswitch services 日本 01             # 经某个节点检测（不影响正在用的节点）
proxyswitch diagnose https://www.youtube.com
proxyswitch rule add openai.com 美国      # 加规则：openai.com 走「美国」这个策略组
proxyswitch rule add /Applications/Telegram.app proxy --type app
proxyswitch rule add 192.168.1.20 direct --type device
proxyswitch rule remove openai.com
proxyswitch final direct                # 其余流量直连；follow 跟随规则文件
proxyswitch sub add https://example.com/sub 机场
proxyswitch add-nodes 'trojan://密码@example.com:443#日本'
proxyswitch ruleset add 广告拦截 reject    # 从规则库按名字添加
proxyswitch group-add 美国 url-test 美|US
proxyswitch import ~/Downloads/config.yaml --preview   # 预览
proxyswitch import https://example.com/config.yaml     # 合并导入；--replace 替换同类设置
proxyswitch export describe > proxyswitch.json         # 配置描述；backup 是备份，core 是内核配置（订阅地址都隐藏）
proxyswitch history                     # 操作记录
proxyswitch undo                        # 撤销最近一次改动
proxyswitch call select_node '{"name":"香港"}'          # 直接调用某个工具
```

加 `--json` 输出完整的 JSON。退出码：0 成功，1 出错，2 用法不对，3 权限不够。

## AI 助手（MCP）

支持 MCP 的 AI 客户端（Claude Desktop、Claude Code、Cursor 等）加上下面的配置，就能让 AI 直接查看状态、切节点、诊断网址、加规则、导入配置：

```json
{
  "mcpServers": {
    "proxyswitch": {
      "command": "/Applications/ProxySwitch.app/Contents/MacOS/ProxySwitch",
      "args": ["mcp"]
    }
  }
}
```

Claude Code 可以用命令添加：

```bash
claude mcp add proxyswitch -- /Applications/ProxySwitch.app/Contents/MacOS/ProxySwitch mcp
```

「自动化」页里有现成的配置，路径是按程序实际的位置生成的，点「复制」就行。

MCP 服务器初始化时会把使用规则告诉 AI 助手：先看状态再动手、只做用户要求的事、改配置前先说明、复杂的改动先预览、改错了用 `undo`、网站打不开先诊断。

### 工具

| 工具 | 权限 | 作用 |
| --- | --- | --- |
| `get_status` | 查看 | 代理状态、配置、节点、模式、局域网共享、出口 IP |
| `list_profiles` | 查看 | 代理配置 |
| `list_nodes` | 查看 | 节点和延迟（`filter`、`limit`） |
| `list_groups` | 查看 | 策略组、现在用的成员和候选 |
| `list_rules` | 查看 | 自定义规则、规则集、其余流量 |
| `list_subscriptions` | 查看 | 订阅（地址隐藏）和手动节点 |
| `list_connections` | 查看 | 现在开着的和最近的连接（`filter`、`limit`） |
| `get_traffic` | 查看 | 按节点、按程序和设备、按天的流量 |
| `get_logs` | 查看 | ProxySwitch 和内核的日志（`lines`） |
| `diagnose_url` | 查看 | 诊断网址（`url`）：命中的规则、出口、结论 |
| `export_config` | 查看 | 导出（`format`：`describe` / `backup` / `core`），订阅地址隐藏 |
| `preview_import` | 查看 | 预览导入（`content` 或 `url`），不改动 |
| `list_changes` | 查看 | 操作记录 |
| `turn_on` / `turn_off` / `toggle` | 日常 | 开关代理（`turn_on` 可带 `profile`） |
| `select_node` | 日常 | 切换节点（`name`，`auto` 是自动选择） |
| `select_group` | 日常 | 给策略组选成员（`group`、`member`） |
| `set_mode` | 日常 | `rule` 或 `global` |
| `test_nodes` | 日常 | 测速（`filter`） |
| `check_services` | 日常 | 服务检测（`node`） |
| `update_subscriptions` / `update_rule_sets` | 日常 | 重新下载 |
| `close_connections` | 日常 | 断开一条（`id`）或全部 |
| `set_share` | 日常 | 开关局域网共享（`enabled`） |
| `add_rule` / `remove_rule` | 完全 | 自定义规则（`value`、`policy`、`type`） |
| `set_final` | 完全 | 其余流量（`policy`，`follow` 跟随规则文件） |
| `add_subscription` / `remove_subscription` | 完全 | 订阅 |
| `add_nodes` | 完全 | 手动节点（`links`） |
| `add_rule_set` / `remove_rule_set` | 完全 | 规则集（`url` 或规则库里的 `library` 名字） |
| `add_group` / `remove_group` | 完全 | 策略组（`name`、`type`、`filter`、`exclude`） |
| `import_config` | 完全 | 导入并生效（`content` 或 `url`，`mode`：`merge` / `replace`） |
| `undo` | 完全 | 撤销最近一次改动 |

规则的去向写 `proxy`（走节点）、`direct`（直连）、`reject`（拦截）或者策略组的名字。规则类型（`type`）：`auto`（域名或 IP，默认）、`domain`、`suffix`、`keyword`、`wildcard`、`regex`、`ip`、`geoip`、`device`、`port`、`app`、`process`、`network`、`logic`。

订阅地址里常带着令牌，经接口列出和导出时只留主机名（`https://example.com/__hidden__`）；把这样的配置描述再导入时，隐藏了的订阅保留现有的。

## ProxySwitch 配置描述（JSON）

导入时认得的一种格式，也是 AI 助手生成配置最方便的写法。字段都可以省略，写了哪些就导入哪些：

```json
{
  "proxyswitch": 1,
  "mode": "rule",
  "subscriptions": [
    {"name": "机场", "url": "https://example.com/sub", "exclude": "过期|剩余", "prefix": "", "dialer": null}
  ],
  "nodes": ["trojan://密码@example.com:443#日本"],
  "groups": [
    {"name": "美国", "type": "url-test", "filter": "美|US", "subscriptions": ["机场"], "interval": 300},
    {"name": "AI", "type": "select", "groups": ["美国"]},
    {"name": "均衡", "type": "load-balance", "filter": "港", "strategy": "consistent-hashing"}
  ],
  "rules": [
    {"type": "suffix", "value": "openai.com", "policy": "AI"},
    {"type": "app", "value": "/Applications/Telegram.app", "policy": "proxy"},
    {"type": "device", "value": "192.168.1.20", "policy": "direct"},
    "DOMAIN-KEYWORD,bank,direct"
  ],
  "ruleSets": [
    {"library": "广告拦截", "policy": "reject"},
    {"url": "https://example.com/netflix.list", "policy": "流媒体", "name": "Netflix"}
  ],
  "final": "proxy",
  "dns": {
    "enabled": true,
    "nameservers": ["https://doh.pub/dns-query", "https://dns.alidns.com/dns-query"],
    "fallback": ["https://1.1.1.1/dns-query"],
    "fallbackViaProxy": true,
    "policies": {"+.corp.example.com": "10.0.0.53"}
  },
  "hosts": {"nas.lan": "192.168.1.5"},
  "ipv6": false,
  "profiles": [{"name": "公司", "type": "http", "host": "10.0.0.1", "port": 8080}],
  "networkRules": [
    {"ssid": "Office", "action": "profile:公司"},
    {"router": "a0:b1:c2:d3:e4:f5", "action": "off"},
    {"other": true, "action": "mode:rule"}
  ],
  "patch": "log-level: info\n"
}
```

- `groups[].type`：`select`（手动选择）、`url-test`（自动选择）、`fallback`（故障转移）、`load-balance`（负载均衡）；`filter` / `exclude` 是节点名的正则（不区分大小写）；`groups` 是也放进来的策略组（可以写「节点」「自动选择」）；`subscriptions` 限定只用哪些订阅的节点（写订阅名，「手动节点」代表手动节点）；`url`、`interval`、`tolerance`、`strategy`（`round-robin`、`consistent-hashing`、`sticky-sessions`）。
- `rules` 里也可以直接写规则行：`类型,内容,去向`（Clash / Surge 的规则类型都认得），组合规则写成 `AND,((DOMAIN,a.com),(NETWORK,UDP)),reject`。
- `ruleSets[].library` 是规则库里的名字；`policy` 不写时纯列表走节点，完整配置按文件里的策略。
- `networkRules[].action`：`off`（关闭代理）、`mode:rule`、`mode:global`、`profile:配置名`。
- 合并导入时同名的策略组、同地址的订阅和规则集、同样的规则会被更新；替换导入时导入的类别整个换掉，没导入的类别不动。
- 设置 →「高级」→「导出」→「配置描述」导出的就是这个格式（带完整的订阅地址），改了再导入就行；经命令行和 AI 助手导出时订阅地址是隐藏的。

## 其他能导入的格式

- **Clash / mihomo 的 YAML**：`proxies` 里的节点存成一条本机订阅；`proxy-providers` 加成订阅（筛选和名字前缀也带上）；`proxy-groups` 变成策略组，成员里的节点名变成按名字筛选，别的组变成包含的组；`rules` 连同引用的 `rule-providers`（网络上的和 inline 的）存成一个规则集，按文件里的策略和 `MATCH` 走；`.mrs` 规则集单独加进规则集列表；`dns`、`hosts`、`ipv6`、`mode` 也导入。端口、TUN、监听这些由 ProxySwitch 管理的设置不导入，`GEOSITE`、`SUB-RULE` 这类规则会提示。
- **Surge / 小火箭的 .conf**：`[Proxy]` 里的 ss、vmess、trojan、http、socks5、hysteria2、snell、tuic 节点转换后存成本机订阅；`[Proxy Group]` 变成策略组（`policy-regex-filter` 当筛选）；`[Rule]` 存成规则集（`DOMAIN-SET`、`RULE-SET` 下载后在原来的位置并入，`AND` / `OR` / `NOT` 组合规则支持）；`[Host]`、`[General]` 的 DNS 和 IPv6 也导入。`[URL Rewrite]`、`[MITM]`、`[Script]` 不导入。
- **Quantumult X 的配置**：`[server_remote]` 加成订阅，`[server_local]` 里的节点转换，`[policy]` 变成策略组（`static` 手动选择、`url-latency-benchmark` 自动选择、`available` 故障转移、`round-robin` / `dest-hash` 负载均衡），`[filter_remote]` 加成规则集（`force-policy` 是统一去向），`[filter_local]` 存成规则集，`[dns]` 的服务器和按域名指定的 DNS 也导入。
- **节点链接**：`ss://`、`ssr://`、`vmess://`、`vless://`、`trojan://`、`hysteria2://`、`tuic://`、`anytls://` 等，一行一条或整段 base64，加成手动节点。
- **规则列表**：纯规则列表加成规则集。
- **网址**：填网址时先下载再认格式。内容是节点列表或只有节点的 Clash 配置时直接加成订阅（以后自动更新）；是完整的 Clash / Surge 配置时，订阅和规则也直接用这个网址，跟着它更新。
- **ProxySwitch 备份**：设置 →「高级」→「导出」→「完整备份」，导入时选「替换」原样恢复。经命令行导出的备份里订阅地址是隐藏的，只适合给别人看，不适合当备份。

设置里的导入在「高级」页（节点页、配置页也有入口），也可以把文件直接拖进设置窗口。导入前一定会先给你看要改动什么。

## URL 命令与快捷指令

```bash
open "proxyswitch://toggle"                          # 开关代理；on、off 同理
open "proxyswitch://use?name=公司"                     # 开启某个配置
open "proxyswitch://node?name=香港"                    # 切换节点；auto 是自动选择
open "proxyswitch://mode?value=global"               # 切换模式
open "proxyswitch://group?name=流媒体&member=日本"       # 切换策略组
open "proxyswitch://run?tool=check_services"          # 执行一个工具（参数写在后面：&node=日本）
open "proxyswitch://import?url=https://example.com/config.yaml"   # 打开导入预览
open "proxyswitch://share/on"
open "proxyswitch://diagnose?url=https://youtube.com"
open "proxyswitch://settings?page=automation"
```

URL 命令和命令行一样受权限限制，但不能直接改配置（网页也能触发 URL 命令）：`run` 只能用查看和日常操作类的工具，导入会先打开预览让你确认。

快捷指令里用「打开 URL」执行这些命令，或者用「运行 Shell 脚本」调用 `proxyswitch` 命令（先安装命令行工具）。

## 按网络自动切换

「自动化」页里加规则：连上某个 Wi‑Fi（或者路由器是某个 MAC / IP）时开启某个配置、关闭代理、切到规则分流或全局代理；「其他网络」在上面都不符合时生效。同一个网络只切一次，之后手动改了不会被改回去，换了网络才会再按规则切。

读 Wi‑Fi 名字要定位权限（macOS 14 起系统这样规定，ProxySwitch 不读取、不保存位置）；不给的话可以按路由器的 MAC 地址认。
