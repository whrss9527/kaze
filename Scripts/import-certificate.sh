#!/bin/bash
# 把 Developer ID Application 证书（.p12，base64 编码）导入一个临时钥匙串，给 codesign 用。发布流程里调用：
#   CERTIFICATE_P12_BASE64=… CERTIFICATE_PASSWORD=… Scripts/import-certificate.sh
# 找到的签名身份（证书的 SHA-1）和钥匙串路径写进 $GITHUB_ENV（没有时打印出来）：
#   CODESIGN_IDENTITY、CODESIGN_KEYCHAIN —— Scripts/build-app.sh 会用它们签名。
# 用完可以 security delete-keychain "$CODESIGN_KEYCHAIN"。
set -euo pipefail

: "${CERTIFICATE_P12_BASE64:?没有设置 CERTIFICATE_P12_BASE64（.p12 证书的 base64）}"
: "${CERTIFICATE_PASSWORD:?没有设置 CERTIFICATE_PASSWORD（导出 .p12 时设的密码）}"

work="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/kaze-signing"
rm -rf "$work" && mkdir -p "$work"
keychain="$work/signing.keychain-db"
keychain_password="$(/usr/bin/openssl rand -hex 24)"
p12="$work/certificate.p12"

# 粘贴时可能带了换行或空格，先去掉。
printf '%s' "$CERTIFICATE_P12_BASE64" | tr -d ' \r\n\t' | base64 --decode > "$p12"
[ -s "$p12" ] || { echo "CERTIFICATE_P12_BASE64 解不出内容"; exit 1; }

security create-keychain -p "$keychain_password" "$keychain"
# 6 小时内不自动锁上（默认 5 分钟就锁，打包慢一点签名就会失败）。
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
if ! security import "$p12" -k "$keychain" -P "$CERTIFICATE_PASSWORD" -f pkcs12 -T /usr/bin/codesign -T /usr/bin/security >/dev/null; then
  rm -f "$p12"
  echo "导入证书失败：密码不对，或者不是含私钥的 .p12"
  exit 1
fi
rm -f "$p12"
# 允许 codesign 直接用私钥，不然会弹授权窗口，CI 里就一直卡着。
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
# 放进钥匙串搜索列表（保留原有的），codesign 才能找到证书链。
# shellcheck disable=SC2046
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')

# Developer ID 的中间证书：系统里一般有；没有的话 codesign 会报 unable to build chain。导入失败不要紧。
for ca in DeveloperIDG2CA DeveloperIDCA; do
  if curl -fsSL --retry 2 -o "$work/$ca.cer" "https://www.apple.com/certificateauthority/$ca.cer"; then
    security import "$work/$ca.cer" -k "$keychain" >/dev/null 2>&1 || true
  fi
done

identities="$(security find-identity -p codesigning "$keychain")"
identity="$(printf '%s\n' "$identities" | awk '/^ *1\)/{print $2; exit}')"
name="$(printf '%s\n' "$identities" | awk -F'"' '/^ *1\)/{print $2; exit}')"
if [ -z "$identity" ]; then
  printf '%s\n' "$identities"
  echo "钥匙串里没有可以签名代码的证书"
  exit 1
fi
echo "签名证书：${name}（${identity}）"
case "$name" in
  "Developer ID Application:"*) ;;
  *) echo "注意：证书不是「Developer ID Application」（是「${name}」），这样签出来的程序公证不会通过" ;;
esac

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "CODESIGN_IDENTITY=$identity"
    echo "CODESIGN_KEYCHAIN=$keychain"
  } >> "$GITHUB_ENV"
else
  echo "CODESIGN_IDENTITY=$identity"
  echo "CODESIGN_KEYCHAIN=$keychain"
fi
