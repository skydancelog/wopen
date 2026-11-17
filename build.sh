#!/usr/bin/env bash
# 基于 OpenWrt 官方 ImageBuilder 构建 Xiaomi CR6608 定制固件
# 用法: bash build.sh    （先编辑 config.env）
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.env}"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

# 兜底默认值（config.env 缺失时仍可运行）
: "${VERSION:=25.12.6}"
: "${TARGET:=ramips}"
: "${SUBTARGET:=mt7621}"
: "${PROFILE:=xiaomi_mi-router-cr6608}"
: "${IB_ARCH:=Linux-x86_64}"
: "${DOWNLOAD_BASE:=https://downloads.openwrt.org}"
: "${EXTRA_IMAGE_NAME:=cr6608custom}"
: "${ROOT_PASSWORD:=ChangeMe-2026}"
: "${LAN_IP:=192.168.1.1}"
: "${HOST_NAME:=CR6608}"
: "${WIFI_2G_SSID:=CR6608-2.4G}"
: "${WIFI_5G_SSID:=CR6608-5G}"
: "${WIFI_PASSWORD:=ChangeMe-2026}"
: "${LUCI_LANG:=zh_cn}"
: "${LUCI_THEME_PATH:=/luci-static/bootstrap}"
: "${PACKAGES_BASE:=luci luci-base luci-theme-bootstrap luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn luci-app-firewall luci-app-package-manager wpad-mbedtls ca-certificates curl ip-full tcpdump-mini htop nano zoneinfo-asia}"
: "${PACKAGES_REMOVE:=-wpad-basic-mbedtls}"
: "${PACKAGES_EXTRA:=}"
: "${ENABLE_CUSTOM_FEED:=1}"
: "${CUSTOM_FEED_NAME:=dllkids}"
: "${CUSTOM_FEED_URL:=https://down.dllkids.xyz/openwrt-feed/25.12/mipsel_24kc/packages.adb}"
: "${CUSTOM_FEED_KEY_URL:=https://down.dllkids.xyz/openwrt-feed/keys/dllkids-feed.pub.pem}"

WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/build}"
DOWNLOAD_DIR="$WORK_DIR/downloads"
FILES_DIR="$WORK_DIR/files"
IB_DIR="$WORK_DIR/imagebuilder"
BIN_DIR="$WORK_DIR/bin"
OUTPUT_DIR="$SCRIPT_DIR/output"

mkdir -p "$DOWNLOAD_DIR" "$OUTPUT_DIR"

echo "[1/8] 检查构建依赖"
for cmd in curl tar sha256sum awk sed find cp; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "缺少必需命令: $cmd" >&2; exit 1; }
done
command -v openssl >/dev/null 2>&1 || { echo "缺少必需命令: openssl（用于生成 root 密码哈希）" >&2; exit 1; }
if ! command -v zstd >/dev/null 2>&1 && ! tar --help 2>/dev/null | grep -q zstd; then
  echo "缺少 zstd：请安装 zstd 后重试（用于解压 ImageBuilder）" >&2
  exit 1
fi

echo "[2/8] 下载官方 ImageBuilder"
IB_FILE="openwrt-imagebuilder-${VERSION}-${TARGET}-${SUBTARGET}.${IB_ARCH}.tar.zst"
IB_URL="$DOWNLOAD_BASE/releases/${VERSION}/targets/${TARGET}/${SUBTARGET}/${IB_FILE}"
ARCHIVE="$DOWNLOAD_DIR/$IB_FILE"
if [ ! -s "$ARCHIVE" ] || [ "${FORCE_DOWNLOAD:-0}" = "1" ]; then
  curl -fL --retry 3 --connect-timeout 20 -o "$ARCHIVE" "$IB_URL"
else
  echo "已存在，跳过下载: $ARCHIVE"
fi

echo "[3/8] 校验 ImageBuilder SHA256"
SUMS_URL="$DOWNLOAD_BASE/releases/${VERSION}/targets/${TARGET}/${SUBTARGET}/sha256sums"
EXPECTED="$(curl -fsSL --retry 3 --max-time 60 "$SUMS_URL" | awk -v want="*$IB_FILE" '$2 == want { print $1; exit }')"
if [ -z "$EXPECTED" ]; then
  echo "无法从官方 sha256sums 获取 $IB_FILE 的校验和" >&2
  exit 1
fi
printf '%s  %s\n' "$EXPECTED" "$ARCHIVE" | sha256sum -c -

echo "[4/8] 解压 ImageBuilder"
rm -rf "$IB_DIR"
mkdir -p "$IB_DIR"
if command -v zstd >/dev/null 2>&1; then
  zstd -dc "$ARCHIVE" | tar -xf - -C "$IB_DIR" --strip-components=1
else
  tar --zstd -xf "$ARCHIVE" -C "$IB_DIR" --strip-components=1
fi
[ -f "$IB_DIR/Makefile" ] || { echo "ImageBuilder 解压结果异常：找不到 Makefile" >&2; exit 1; }

echo "[5/8] 注入第三方 APK 源"
if [ "$ENABLE_CUSTOM_FEED" = "1" ]; then
  # 25.12 的 ImageBuilder 使用 apk，仓库文件是 repositories（每行一个 packages.adb URL），
  # 公钥放在 keys/ 目录；make image 会通过 --repositories-file / APK_KEYS 读取它们。
  KEY_FILE="$IB_DIR/keys/${CUSTOM_FEED_NAME}-feed.pub.pem"
  curl -fsSL --retry 3 --connect-timeout 20 -o "$KEY_FILE" "$CUSTOM_FEED_KEY_URL"
  chmod 644 "$KEY_FILE"

  REPO_FILE="$IB_DIR/repositories"
  if [ ! -f "$REPO_FILE" ]; then
    echo "ImageBuilder 中找不到 repositories 文件，无法注入第三方源" >&2
    exit 1
  fi
  grep -qxF "$CUSTOM_FEED_URL" "$REPO_FILE" || printf '%s\n' "$CUSTOM_FEED_URL" >> "$REPO_FILE"
  echo "已添加构建期源: $CUSTOM_FEED_URL"
fi

echo "[6/8] 生成定制覆盖层"
rm -rf "$FILES_DIR"
mkdir -p "$FILES_DIR/etc/uci-defaults"
cp -a "$SCRIPT_DIR/overlay/." "$FILES_DIR/"

# 让设备端也能从该第三方源更新/安装插件
if [ "$ENABLE_CUSTOM_FEED" = "1" ]; then
  mkdir -p "$FILES_DIR/etc/apk/repositories.d" "$FILES_DIR/etc/apk/keys"
  cp "$KEY_FILE" "$FILES_DIR/etc/apk/keys/${CUSTOM_FEED_NAME}-feed.pub.pem"
  printf '%s\n' "$CUSTOM_FEED_URL" > "$FILES_DIR/etc/apk/repositories.d/customfeeds.list"
fi

# 生成 root 密码哈希（优先 SHA-512，兼容旧 OpenSSL 回退 MD5-crypt）
SALT="$(LC_ALL=C head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
if ROOT_HASH="$(printf '%s\n' "$ROOT_PASSWORD" | openssl passwd -6 -salt "$SALT" -stdin 2>/dev/null)" && [ -n "$ROOT_HASH" ]; then
  :
elif ROOT_HASH="$(printf '%s\n' "$ROOT_PASSWORD" | openssl passwd -1 -salt "$SALT" -stdin 2>/dev/null)" && [ -n "$ROOT_HASH" ]; then
  echo "警告: 当前 OpenSSL 不支持 SHA-512，已回退到 MD5-crypt 哈希" >&2
else
  echo "无法生成 root 密码哈希" >&2
  exit 1
fi

# POSIX shell 单引号安全转义，避免密码/SSID 中的特殊字符破坏脚本
shquote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}
# sed 替换值转义（分隔符使用 |）
sed_escape() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

TPL="$SCRIPT_DIR/overlay/etc/uci-defaults/99-cr6608-custom"
DST="$FILES_DIR/etc/uci-defaults/99-cr6608-custom"
sed \
  -e "s|@ROOT_HASH@|$(sed_escape "$(shquote "$ROOT_HASH")")|g" \
  -e "s|@LAN_IP@|$(sed_escape "$(shquote "$LAN_IP")")|g" \
  -e "s|@HOST_NAME@|$(sed_escape "$(shquote "$HOST_NAME")")|g" \
  -e "s|@WIFI_2G_SSID@|$(sed_escape "$(shquote "$WIFI_2G_SSID")")|g" \
  -e "s|@WIFI_5G_SSID@|$(sed_escape "$(shquote "$WIFI_5G_SSID")")|g" \
  -e "s|@WIFI_PASSWORD@|$(sed_escape "$(shquote "$WIFI_PASSWORD")")|g" \
  -e "s|@LUCI_LANG@|$(sed_escape "$(shquote "$LUCI_LANG")")|g" \
  -e "s|@LUCI_THEME_PATH@|$(sed_escape "$(shquote "$LUCI_THEME_PATH")")|g" \
  "$TPL" > "$DST"
chmod 755 "$DST"

sed \
  -e "s|@VERSION@|$(sed_escape "$VERSION")|g" \
  -e "s|@PROFILE@|$(sed_escape "$PROFILE")|g" \
  "$SCRIPT_DIR/overlay/etc/banner" > "$FILES_DIR/etc/banner"

echo "[7/8] 构建镜像"
PACKAGES="$PACKAGES_BASE $PACKAGES_REMOVE $PACKAGES_EXTRA"
rm -rf "$BIN_DIR"
mkdir -p "$BIN_DIR"
(
  cd "$IB_DIR"
  make image \
    PROFILE="$PROFILE" \
    PACKAGES="$PACKAGES" \
    FILES="$FILES_DIR" \
    BIN_DIR="$BIN_DIR" \
    EXTRA_IMAGE_NAME="$EXTRA_IMAGE_NAME"
)

# 记录最终包清单（部分版本没有 manifest 目标，忽略失败）
(
  cd "$IB_DIR"
  make manifest PROFILE="$PROFILE" PACKAGES="$PACKAGES"
) > "$OUTPUT_DIR/package-manifest.txt" 2>/dev/null || true

echo "[8/8] 整理产物"
FACTORY="$(find "$BIN_DIR" -maxdepth 1 -type f -name "*-${PROFILE}-squashfs-firmware*.bin" -print -quit)"
SYSUPGRADE="$(find "$BIN_DIR" -maxdepth 1 -type f -name "*-${PROFILE}-squashfs-sysupgrade*.bin" -print -quit)"
if [ -z "$FACTORY" ] || [ -z "$SYSUPGRADE" ]; then
  echo "未找到预期镜像文件，请检查 $BIN_DIR" >&2
  exit 1
fi
cp "$FACTORY" "$OUTPUT_DIR/openwrt-${VERSION}-cr6608-factory.bin"
cp "$SYSUPGRADE" "$OUTPUT_DIR/openwrt-${VERSION}-cr6608-sysupgrade.bin"
sha256sum "$OUTPUT_DIR"/*.bin > "$OUTPUT_DIR/sha256sums.txt"

echo
echo "构建完成。"
echo "  factory   : $OUTPUT_DIR/openwrt-${VERSION}-cr6608-factory.bin   （从原厂固件刷入）"
echo "  sysupgrade: $OUTPUT_DIR/openwrt-${VERSION}-cr6608-sysupgrade.bin （从 OpenWrt 升级）"
echo "  校验和    : $OUTPUT_DIR/sha256sums.txt"
echo "  包清单    : $OUTPUT_DIR/package-manifest.txt"
echo
echo "首次启动后管理地址: http://$LAN_IP"
echo "root 密码与 Wi-Fi 密码取自 config.env（uci-defaults 只在首次启动执行一次）。"
