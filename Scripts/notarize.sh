#!/bin/bash
# 把签好名的 zip 提交苹果公证，通过后把公证票据钉（staple）到 .app 上，再重新打成同名的 zip。
# 钉上票据后，用户第一次打开时就算没联网，系统也能确认它经过了公证。
#   Scripts/notarize.sh dist/Proxi-macos.zip dist/Proxi-macos-arm64.zip …
# 凭据二选一（发布流程从 GitHub Secrets 传进来，见 docs/signing.md）：
#   App Store Connect API 密钥：NOTARY_KEY_P8（.p8 文件的内容，或者它的 base64）、NOTARY_KEY_ID、NOTARY_ISSUER_ID（个人密钥不填）
#   Apple ID：NOTARY_APPLE_ID、NOTARY_PASSWORD（App 专用密码）、NOTARY_TEAM_ID
set -euo pipefail

[ $# -gt 0 ] || { echo "用法：Scripts/notarize.sh 文件.zip …"; exit 1; }
work="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/proxi-notary"
rm -rf "$work" && mkdir -p "$work"
trap 'rm -f "$work/AuthKey.p8"' EXIT

auth=()
if [ -n "${NOTARY_KEY_P8:-}" ]; then
  key="$work/AuthKey.p8"
  if printf '%s' "$NOTARY_KEY_P8" | grep -q "BEGIN PRIVATE KEY"; then
    printf '%s\n' "$NOTARY_KEY_P8" > "$key"
  else
    printf '%s' "$NOTARY_KEY_P8" | tr -d ' \r\n\t' | base64 --decode > "$key"
  fi
  auth=(--key "$key" --key-id "${NOTARY_KEY_ID:?没有设置 NOTARY_KEY_ID}")
  if [ -n "${NOTARY_ISSUER_ID:-}" ]; then
    auth+=(--issuer "$NOTARY_ISSUER_ID")
  fi
elif [ -n "${NOTARY_APPLE_ID:-}" ]; then
  auth=(--apple-id "$NOTARY_APPLE_ID"
        --password "${NOTARY_PASSWORD:?没有设置 NOTARY_PASSWORD（App 专用密码）}"
        --team-id "${NOTARY_TEAM_ID:?没有设置 NOTARY_TEAM_ID}")
else
  echo "没有公证凭据：设置 NOTARY_KEY_P8 + NOTARY_KEY_ID（+ NOTARY_ISSUER_ID），或者 NOTARY_APPLE_ID + NOTARY_PASSWORD + NOTARY_TEAM_ID"
  exit 1
fi

# notarytool --output-format json 的输出里取一个字段。
json_field() {
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1" "$2" 2>/dev/null || true
}

# 先把所有包都传上去（苹果那边同时处理），再逐个等结果。
ids=()
for zip in "$@"; do
  [ -f "$zip" ] || { echo "找不到 $zip"; exit 1; }
  name="$(basename "$zip")"
  out="$work/submit-$name.json"
  echo "上传 $name 提交公证"
  if ! xcrun notarytool submit "$zip" "${auth[@]}" --output-format json > "$out"; then
    cat "$out" || true
    echo "提交失败：$name"
    exit 1
  fi
  id="$(json_field "$out" id)"
  [ -n "$id" ] || { cat "$out"; echo "没拿到提交编号：$name"; exit 1; }
  echo "  提交编号 $id"
  ids+=("$id")
done

i=0
for zip in "$@"; do
  id="${ids[$i]}"
  i=$((i + 1))
  name="$(basename "$zip")"
  out="$work/wait-$name.json"
  xcrun notarytool wait "$id" "${auth[@]}" --output-format json > "$out" || true
  status="$(json_field "$out" status)"
  echo "${name}：公证结果 ${status:-未知}"
  if [ "$status" != "Accepted" ]; then
    cat "$out" || true
    echo "===== 公证日志（为什么没通过） ====="
    xcrun notarytool log "$id" "${auth[@]}" || true
    exit 1
  fi
  # 解压、钉票据、确认系统认可，再压回原来的文件。
  dir="$work/staple-${name%.zip}"
  rm -rf "$dir" && mkdir -p "$dir"
  ditto -x -k "$zip" "$dir"
  app="$dir/Proxi.app"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
  target="$(cd "$(dirname "$zip")" && pwd)/$name"
  rm -f "$target"
  (cd "$dir" && ditto -c -k --keepParent Proxi.app "$target")
  echo "${name}：已钉上公证票据"
done
