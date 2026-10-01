# 签名与公证

发布流程（`.github/workflows/release.yml`）在仓库的 Secrets 里找到 Developer ID 证书和公证凭据时，会：

1. 把证书导入一个临时钥匙串（`Scripts/import-certificate.sh`）；
2. 用证书签名程序，带 hardened runtime 和安全时间戳（`Scripts/build-app.sh`）；
3. 把三个 zip 提交苹果公证，通过后把票据钉到 `.app` 上再重新打包（`Scripts/notarize.sh`）；
4. 算校验和、上传，Release 说明末尾注明「已用 Developer ID 签名并通过苹果公证」。

用户下载这样的包，解压后双击就能打开，不会再被 Gatekeeper 拦下。没有配置时照旧 ad-hoc 签名，发布日志里会有一条警告。

下面是一次性的准备工作，大约半小时（不算苹果审核开发者账号的时间）。

## 一、加入 Apple Developer Program

用 Apple ID 在 [developer.apple.com/programs/enroll](https://developer.apple.com/programs/enroll/) 或 Apple Developer App 里以**个人**身份注册，年费 99 美元（中国大陆 688 元）。Apple ID 需要开启双重认证。审核通过后会收到邮件。

Developer ID 签名和公证用个人账号就可以，不需要公司。

## 二、创建并导出 Developer ID Application 证书

1. 在 Mac 上打开 Xcode → 设置 → Accounts，登录开发者账号，选中团队，点「Manage Certificates…」，左下角「+」→「Developer ID Application」。
   （也可以在开发者网站的 Certificates, Identifiers & Profiles 里创建，需要先用「钥匙串访问 → 证书助理 → 从证书颁发机构请求证书」生成 CSR。）
2. 打开「钥匙串访问」，左边选「登录」，上面选「我的证书」，找到「Developer ID Application: 你的名字 (团队 ID)」。展开能看到下面的私钥，说明私钥在这台 Mac 上。
3. 在证书上右键 →「导出…」，格式选「个人信息交换 (.p12)」，设一个密码。
4. 转成一行 base64，复制到剪贴板：

   ```bash
   base64 -i DeveloperID.p12 | pbcopy
   ```

## 三、准备公证凭据（二选一）

**A. App Store Connect API 密钥（推荐）**

1. 登录 [App Store Connect](https://appstoreconnect.apple.com) → 用户和访问 → 集成 → App Store Connect API。第一次用要先点「请求访问」。
2. 在「团队密钥」里生成一个密钥，访问权限选「开发者」。
3. 下载 `.p8` 文件（只能下载一次，保存好），记下页面上的 **密钥 ID** 和 **Issuer ID**。

用个人密钥（个人资料里生成的）也可以，这时不填 Issuer ID。

**B. Apple ID + App 专用密码**

1. 在 [account.apple.com](https://account.apple.com) → 登录与安全 → App 专用密码，生成一个。
2. 在开发者网站的「会员资格详细信息」里找到 10 位的 **团队 ID**。

## 四、填进 GitHub Secrets

仓库 → Settings → Secrets and variables → Actions → New repository secret，逐个添加：

| 名字 | 内容 |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | 第二步复制的 base64 |
| `MACOS_CERTIFICATE_PASSWORD` | 导出 .p12 时设的密码 |
| `NOTARY_KEY_P8` | A：`.p8` 文件的全部内容，直接粘贴（包括 BEGIN / END 两行） |
| `NOTARY_KEY_ID` | A：密钥 ID |
| `NOTARY_ISSUER_ID` | A：Issuer ID（个人密钥不填） |
| `NOTARY_APPLE_ID` | B：Apple ID 邮箱 |
| `NOTARY_PASSWORD` | B：App 专用密码 |
| `NOTARY_TEAM_ID` | B：团队 ID |

A 和 B 填一组就行，两组都填时用 A。

## 五、发布

Actions → release → Run workflow，填新的版本标签（比如 `v0.7.0`）。日志里：

- 「导入签名证书」会显示证书名字，应该是 `Developer ID Application: …`；
- 「提交苹果公证并钉上票据」通常几分钟，最后 `spctl` 显示 `source=Notarized Developer ID` 就成功了；没通过时会打印苹果给的公证日志，里面写着是哪个文件、什么原因。

## 要知道的几件事

- **一键更新会认签名**：从第一个签名版开始，程序只安装同一个团队 ID 签名的新版本，别人重新签过名的包即使校验和对得上也不装。旧的 ad-hoc 版本更新到签名版不受影响。换证书（比如五年到期后）团队 ID 不变，更新照常；但之后不要再发 ad-hoc 签名的版本，不然签名版的用户没法一键更新，只能去发布页手动下载。Secrets 失效时发布日志里会出现「没有配置 MACOS_CERTIFICATE_P12」的警告，看到它先别发。
- **证书过期**：Developer ID 证书有效期五年。签名带着安全时间戳，已经发布的版本过期后照样能打开；发新版本前换一张新证书，更新 `MACOS_CERTIFICATE_P12` 和密码。
- **公证不审核功能**：公证只是苹果的自动恶意软件扫描，不看功能，一般几分钟出结果。
- **私钥保管**：`.p12` 和 `.p8` 只放在 GitHub Secrets 里，不要提交进仓库。泄露了就到开发者网站吊销证书或密钥，再换新的。

## 在自己的 Mac 上签名和公证

证书在登录钥匙串里时：

```bash
CODESIGN_IDENTITY="Developer ID Application: 你的名字 (团队 ID)" VERSION=0.7.0 THIN_ARCHIVES=1 Scripts/build-app.sh
NOTARY_APPLE_ID=… NOTARY_PASSWORD=… NOTARY_TEAM_ID=… \
  Scripts/notarize.sh dist/Proxi-macos.zip dist/Proxi-macos-arm64.zip dist/Proxi-macos-x86_64.zip
```
