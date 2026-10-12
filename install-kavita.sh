#!/usr/bin/env bash
set -Eeuo pipefail

# Kavita Linux 一键安装脚本（systemd）
# 支持 x86_64/amd64、aarch64/arm64
# 需要 root、systemd、curl 或 wget、tar、python3

SERVICE="kavita"
INSTALL_DIR="/opt/Kavita"
CONFIG_DIR="/var/lib/kavita"
BOOKS_DIR="/srv/books"
PORT="5000"
MAX_RETRIES=3
RETRY_DELAY=5

die() {
    echo "错误：$*" >&2
    exit 1
}

ask_value() {
    local prompt="$1" default="$2" value
    read -r -p "${prompt} [${default}]: " value
    printf '%s' "${value:-$default}"
}

ask_dir() {
    local label="$1" default="$2" path
    path="$(ask_value "$label" "$default")"
    if [[ -e "$path" && ! -d "$path" ]]; then
        die "路径已存在但不是目录：$path"
    fi
    if [[ ! -d "$path" ]]; then
        read -r -p "目录不存在，是否创建？[Y/n]: " answer
        case "${answer:-Y}" in
            [Yy]|[Yy][Ee][Ss]|"") mkdir -p -- "$path" ;;
            *) die "用户取消创建目录：$path" ;;
        esac
    fi
    printf '%s' "$path"
}

# 1. 前置环境与依赖检查
[[ $EUID -eq 0 ]] || die "请使用 sudo 或 root 运行。"
command -v systemctl >/dev/null || die "未检测到 systemd。"
command -v tar >/dev/null || die "缺少 tar。"
command -v python3 >/dev/null || die "缺少 python3，请先安装。"

# 检查 nologin 路径，兼容不同发行版
NOLOGIN_PATH="/usr/sbin/nologin"
[[ -x "$NOLOGIN_PATH" ]] || NOLOGIN_PATH="/usr/bin/nologin"
[[ -x "$NOLOGIN_PATH" ]] || die "未找到 nologin，请确认系统支持创建系统用户。"

# 检查 curl 或 wget
if command -v curl >/dev/null; then
    DOWNLOADER="curl"
elif command -v wget >/dev/null; then
    DOWNLOADER="wget"
else
    die "请先安装 curl 或 wget。"
fi

# 2. 收集用户配置
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64) ASSET_ARCH="x64" ;;
    aarch64|arm64) ASSET_ARCH="arm64" ;;
    *) die "暂不支持架构：$ARCH（支持 x86_64 和 aarch64）" ;;
esac

echo "配置 Kavita 安装参数（直接回车使用默认值）："
read -r -p "Web 端口 [5000]: " PORT
PORT="${PORT:-5000}"
# 强制十进制解析，避免前导零（如 080）被误认为八进制
[[ "$PORT" =~ ^[0-9]+$ ]] && (( 10#$PORT >= 1 && 10#$PORT <= 65535 )) \

    || die "端口必须是 1–65535 的数字。"

INSTALL_DIR="$(ask_dir "程序安装目录" "$INSTALL_DIR")"
CONFIG_DIR="$(ask_dir "配置/数据库目录" "$CONFIG_DIR")"
BOOKS_DIR="$(ask_dir "EPUB 书库目录" "$BOOKS_DIR")"

if [[ "$INSTALL_DIR" == "$CONFIG_DIR" || "$INSTALL_DIR" == "$BOOKS_DIR" ]]; then
    die "程序目录不能与配置目录或书库目录相同。"
fi

# 3. 创建系统用户与目录权限
if ! id "$SERVICE" >/dev/null 2>&1; then
    useradd --system --user-group --home-dir "$CONFIG_DIR" \
        --shell "$NOLOGIN_PATH" "$SERVICE"
fi

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$BOOKS_DIR"
chown -R "$SERVICE:$SERVICE" "$INSTALL_DIR" "$CONFIG_DIR"
# 书库目录保留 root 所有权，服务用户获得读取及遍历权限
chown -R root:"$SERVICE" "$BOOKS_DIR"
chmod -R 750 "$BOOKS_DIR"

# 4. 带重试机制的网络请求与下载
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

download_with_retry() {
    local url="$1" output="$2"
    for i in $(seq 1 $MAX_RETRIES); do
        echo "正在下载（尝试 $i/$MAX_RETRIES）：$url"
        if [[ "$DOWNLOADER" == "curl" ]]; then
            curl -fL --connect-timeout 15 --max-time 120 --retry 3 "$url" -o "$output" && return 0
        else
            wget --timeout=15 --tries=3 "$url" -O "$output" && return 0
        fi
        echo "下载失败，${RETRY_DELAY}秒后重试..."
        sleep $RETRY_DELAY
    done
    die "下载失败，已达最大重试次数：$url"
}

echo "正在查询 GitHub 最新 release..."
RELEASE_JSON_FILE="$TMP_DIR/release.json"
download_with_retry "https://api.github.com/repos/Kareadita/Kavita/releases/latest" "$RELEASE_JSON_FILE"

# 从 JSON 中提取下载链接和 SHA256 校验和
ASSET_INFO="$(
    python3 -c '
import json, sys
data = json.load(sys.stdin)
arch = sys.argv[1]
for asset in data.get("assets", []):
    name = asset.get("name", "")
    if name == f"kavita-linux-{arch}.tar.gz":
        digest = asset.get("digest", "")
        sha256 = digest.split(":")[-1] if ":" in digest else ""
        print(f"{asset[\"browser_download_url\"]}|{sha256}")
        break
' "$ASSET_ARCH" < "$RELEASE_JSON_FILE"
)" || die "解析 GitHub Release 信息失败，请检查 python3 和网络连接。"

ASSET_URL="${ASSET_INFO%%|*}"
EXPECTED_SHA256="${ASSET_INFO##*|}"

[[ -n "$ASSET_URL" ]] || die "最新 release 中未找到 kavita-linux-${ASSET_ARCH}.tar.gz。"

# 5. 下载并校验文件完整性
ARCHIVE="$TMP_DIR/kavita.tar.gz"
download_with_retry "$ASSET_URL" "$ARCHIVE"

if [[ -n "$EXPECTED_SHA256" ]]; then
    echo "正在校验文件完整性 (SHA256)..."
    ACTUAL_SHA256="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
    if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
        die "SHA256 校验失败！\n预期: $EXPECTED_SHA256\n实际: $ACTUAL_SHA256\n文件可能已被篡改，已中止安装。"
    fi
    echo "校验通过。"
else
    echo "警告：未从 GitHub 获取到 SHA256 校验和，跳过完整性验证。"
fi

# 6. 解压与安装
mkdir "$TMP_DIR/extract"
tar -xzf "$ARCHIVE" -C "$TMP_DIR/extract"

BIN="$(find "$TMP_DIR/extract" -type f -name Kavita -print -quit)"
[[ -n "$BIN" ]] || die "压缩包中未找到 Kavita 可执行文件。"
SOURCE_DIR="$(dirname "$BIN")"

# 保留配置目录，避免覆盖既有数据库或用户数据
cp -a "$SOURCE_DIR/." "$INSTALL_DIR/"
chown -R "$SERVICE:$SERVICE" "$INSTALL_DIR" "$CONFIG_DIR"

# 7. 生成 systemd 服务文件
cat > /etc/systemd/system/kavita.service <<EOF
[Unit]
Description=Kavita Server
After=network.target

[Service]
Type=simple
User=$SERVICE
Group=$SERVICE
WorkingDirectory=$INSTALL_DIR
Environment=KAVITA_CONFIG_DIR=$CONFIG_DIR
Environment=KAVITA_PORT=$PORT
ExecStart=$INSTALL_DIR/Kavita
TimeoutStopSec=20
KillMode=process
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now kavita.service

echo
echo "✅ 安装完成。"
echo "服务状态：systemctl status kavita"
echo "查看日志：journalctl -u kavita -f"
echo "访问地址：http://服务器IP:$PORT"
echo "书库目录：$BOOKS_DIR"
echo
echo "首次登录后，在 Kavita 的服务器设置中添加书库，类型选择 Books，"
echo "目录选择：$BOOKS_DIR"
