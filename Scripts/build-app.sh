#!/bin/bash
# 编译并组装 Proxi.app（通用二进制），带上内核 mihomo 和 GeoIP 数据库，签名后打成 dist/Proxi-macos.zip。
#   VERSION=1.0.0 Scripts/build-app.sh          发布构建
#   CONFIG=debug ARCHS="" Scripts/build-app.sh   本机架构的调试构建
#   SKIP_CORE=1 Scripts/build-app.sh             不下载内核（只能用外部代理的功能）
#   THIN_ARCHIVES=1 Scripts/build-app.sh         另外打两个单架构的精简包（一键更新用，只有通用包一半大）
#   CODESIGN_IDENTITY="Developer ID Application: …" Scripts/build-app.sh
#                                                用开发者证书签名（可以是证书名字或 SHA-1），带安全时间戳，之后能提交公证（Scripts/notarize.sh）；
#                                                不设时 ad-hoc 签名。CODESIGN_KEYCHAIN 可以指定证书所在的钥匙串。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
CONFIG="${CONFIG:-release}"
ARCHS="${ARCHS---arch arm64 --arch x86_64}"
CORE_VERSION="${CORE_VERSION:-v1.19.31}"
CORE_CACHE="${CORE_CACHE:-.core-cache}"

# 下载到缓存目录，已有就跳过。
fetch() {
  local url="$1" dest="$2"
  if [ -s "$dest" ]; then return 0; fi
  echo "下载 $url"
  curl -fsSL --retry 3 --retry-delay 3 -o "$dest.tmp" "$url" && mv "$dest.tmp" "$dest"
}

# 签名。都开 hardened runtime（公证要求；ad-hoc 的构建也开，CI 里测到的就是发布出去的运行方式）。
# 有开发者证书时加安全时间戳（公证要求，证书过期后签名照样有效）；ad-hoc 签名不能带时间戳。
# 由内向外签：先签 mihomo，再签整个 .app，不用 --deep（它会用同样的参数重签里面的东西）。
IDENTITY="${CODESIGN_IDENTITY:--}"
# 程序本身带上权限声明（Resources/Proxi.entitlements：读 Wi‑Fi 名字要的定位权限），内核不用。
ENTITLEMENTS="Resources/Proxi.entitlements"
sign() {
  local args=(--force --options runtime --sign "$IDENTITY")
  if [ "$IDENTITY" != "-" ]; then
    args+=(--timestamp)
  fi
  if [ -n "${CODESIGN_KEYCHAIN:-}" ]; then
    args+=(--keychain "$CODESIGN_KEYCHAIN")
  fi
  if [ -n "${2:-}" ]; then
    args+=(--entitlements "$2")
  fi
  codesign "${args[@]}" "$1"
}

# shellcheck disable=SC2086
swift build -c "$CONFIG" $ARCHS --product Proxi
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c "$CONFIG" $ARCHS --show-bin-path)"

APP="dist/Proxi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp "$BIN_DIR/Proxi" "$APP/Contents/MacOS/Proxi"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 界面文字的翻译：英文和简体中文（代码里写的是中文原文，见 Sources/Proxi/App/AppLanguage.swift）。
for lproj in Resources/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done
# 关于页的赞赏码（「请我喝杯咖啡」）。
[ -f Resources/donate-wechat.png ] && cp Resources/donate-wechat.png "$APP/Contents/Resources/donate-wechat.png"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -z "${SKIP_CORE:-}" ]; then
  # 内核：mihomo（Clash Meta），两个架构的发布包合成一个通用二进制。
  mkdir -p "$CORE_CACHE"
  for arch in arm64 amd64-compatible; do
    gz="$CORE_CACHE/mihomo-darwin-$arch-$CORE_VERSION.gz"
    fetch "https://github.com/MetaCubeX/mihomo/releases/download/$CORE_VERSION/mihomo-darwin-$arch-$CORE_VERSION.gz" "$gz"
    gunzip -c "$gz" > "$CORE_CACHE/mihomo-$arch"
    chmod +x "$CORE_CACHE/mihomo-$arch"
  done
  lipo -create -output "$APP/Contents/MacOS/mihomo" "$CORE_CACHE/mihomo-arm64" "$CORE_CACHE/mihomo-amd64-compatible"
  chmod +x "$APP/Contents/MacOS/mihomo"
  # GeoIP 数据库（GEOIP,CN 规则要用）。
  fetch "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb" "$CORE_CACHE/country.mmdb" \
    || fetch "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb" "$CORE_CACHE/country.mmdb"
  cp "$CORE_CACHE/country.mmdb" "$APP/Contents/Resources/country.mmdb"
  fetch "https://raw.githubusercontent.com/MetaCubeX/mihomo/$CORE_VERSION/LICENSE" "$CORE_CACHE/mihomo-LICENSE.txt"
  cp "$CORE_CACHE/mihomo-LICENSE.txt" "$APP/Contents/Resources/mihomo-LICENSE.txt"
  sign "$APP/Contents/MacOS/mihomo"
  echo "内核 mihomo ${CORE_VERSION}：$(lipo -archs "${APP}/Contents/MacOS/mihomo")"
fi

# 没有开发者证书时用 ad-hoc 签名，Apple 芯片上必须有签名才能运行。
sign "$APP" "$ENTITLEMENTS"
codesign --verify --deep --strict "$APP"
if [ "$IDENTITY" = "-" ]; then
  echo "签名：ad-hoc"
else
  echo "签名：$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')"
fi

(cd dist && rm -f Proxi-macos.zip && ditto -c -k --keepParent Proxi.app Proxi-macos.zip)
echo "已生成 ${APP} 和 dist/Proxi-macos.zip（版本 ${VERSION}）"

if [ -n "${THIN_ARCHIVES:-}" ]; then
  # 从通用包里各取一种芯片的部分：内核占了包的大头，单架构的包只有一半大。
  for arch in arm64 x86_64; do
    dir="dist/thin-${arch}"
    rm -rf "$dir" && mkdir -p "$dir"
    ditto "$APP" "${dir}/Proxi.app"
    missing=""
    for bin in "${dir}/Proxi.app/Contents/MacOS/Proxi" "${dir}/Proxi.app/Contents/MacOS/mihomo"; do
      [ -f "$bin" ] || continue
      archs="$(lipo -archs "$bin")"
      if [ "$archs" = "$arch" ]; then
        continue
      elif [[ " $archs " == *" $arch "* ]]; then
        lipo "$bin" -thin "$arch" -output "${bin}.thin"
        mv "${bin}.thin" "$bin"
        chmod +x "$bin"
      else
        missing="$bin"
      fi
    done
    if [ -n "$missing" ]; then
      echo "跳过 ${arch} 精简包：${missing} 里没有这个架构"
      rm -rf "$dir"
      continue
    fi
    if [ -f "${dir}/Proxi.app/Contents/MacOS/mihomo" ]; then
      sign "${dir}/Proxi.app/Contents/MacOS/mihomo"
    fi
    sign "${dir}/Proxi.app" "$ENTITLEMENTS"
    codesign --verify --deep --strict "${dir}/Proxi.app"
    (cd "$dir" && ditto -c -k --keepParent Proxi.app "../Proxi-macos-${arch}.zip")
    echo "已生成 dist/Proxi-macos-${arch}.zip：$(du -h "dist/Proxi-macos-${arch}.zip" | cut -f1)"
  done
fi
