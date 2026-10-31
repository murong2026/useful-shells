#!/usr/bin/env bash
set -euo pipefail
umask 077

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

ask() {
  local var="$1" prompt="$2" value
  read -r -p "$prompt: " value
  [[ -n "$value" ]] || die "$prompt 不能为空"
  printf -v "$var" '%s' "$value"
}

ask_secret() {
  local var="$1" prompt="$2" value
  read -r -s -p "$prompt: " value
  printf '\n'
  [[ -n "$value" ]] || die "$prompt 不能为空"
  printf -v "$var" '%s' "$value"
}

ask_default() {
  local var="$1" prompt="$2" default="$3" value
  read -r -p "$prompt [$default]: " value
  value="${value:-$default}"
  printf -v "$var" '%s' "$value"
}

validate_port() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[0-9]{1,5}$ ]] || die "$name 必须是 1–65535 的端口号"
  (( 10#$value >= 1 && 10#$value <= 65535 )) || die "$name 必须是 1–65535 的端口号"
}

validate_uuid() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
    || die "$name 不是标准 UUID 格式"
}

validate_key() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[A-Za-z0-9_+/=-]+$ ]] || die "$name 含有不支持的字符"
}

validate_short_id() {
  local name="$1" value="$2"
  # Reality short ID：最多 8 字节，即最多 16 个十六进制字符；允许空值。
  [[ "$value" =~ ^([0-9A-Fa-f]{2}){0,8}$ ]] \
    || die "$name 必须是最多 16 个十六进制字符，且长度为偶数"
}

printf '输入 A、B 两台 VPS 的 sing-box 节点参数。\n'
printf 'A 入站使用 A 的 UUID、私钥和 short ID；B 出站使用 B 的 UUID、公钥和 short ID。\n\n'

# A：面向客户端的 Reality 入站
ask A_PORT 'A 的 VLESS Reality 入站端口'
validate_port 'A 入站端口' "$A_PORT"
A_PORT=$((10#$A_PORT))

ask A_UUID 'A 入站给客户端使用的 UUID'
validate_uuid 'A UUID' "$A_UUID"

ask A_SNI 'A Reality 入站的握手目标域名'
[[ "$A_SNI" =~ ^[A-Za-z0-9.-]+$ ]] || die 'A 握手目标域名格式不正确'

ask_default A_HANDSHAKE_PORT 'A Reality 握手目标端口' '443'
validate_port 'A 握手目标端口' "$A_HANDSHAKE_PORT"
A_HANDSHAKE_PORT=$((10#$A_HANDSHAKE_PORT))

ask_secret A_PRIVATE_KEY 'A Reality 私钥'
validate_key 'A Reality 私钥' "$A_PRIVATE_KEY"

read -r -p 'A Reality short_id（若 A 确实配置为空才留空）: ' A_SHORT_ID
validate_short_id 'A short_id' "$A_SHORT_ID"

ask_default A_FLOW 'A 入站 flow' 'xtls-rprx-vision'
[[ "$A_FLOW" == 'xtls-rprx-vision' ]] || die '此脚本目前只生成 xtls-rprx-vision 配置'

# B：A 要连接的 Reality 入站
ask B_ADDRESS 'B 的公网 IP 或域名'
[[ "$B_ADDRESS" =~ ^[A-Za-z0-9.:-]+$ ]] || die 'B 地址格式不正确'

ask B_PORT 'B 的 VLESS Reality 入站端口'
validate_port 'B 入站端口' "$B_PORT"
B_PORT=$((10#$B_PORT))

ask B_UUID 'B 入站供 A 使用的 UUID'
validate_uuid 'B UUID' "$B_UUID"

ask_default B_FLOW 'B 入站 flow' 'xtls-rprx-vision'
[[ "$B_FLOW" == 'xtls-rprx-vision' ]] || die '此脚本目前只生成 xtls-rprx-vision 配置'

ask B_SNI 'B Reality SNI'
[[ "$B_SNI" =~ ^[A-Za-z0-9.-]+$ ]] || die 'B SNI 格式不正确'

ask B_PUBLIC_KEY 'B Reality 公钥'
validate_key 'B Reality 公钥' "$B_PUBLIC_KEY"

read -r -p 'B Reality short_id（若 B 确实配置为空才留空）: ' B_SHORT_ID
validate_short_id 'B short_id' "$B_SHORT_ID"

ask_default FINGERPRINT 'uTLS fingerprint' 'chrome'
[[ "$FINGERPRINT" =~ ^[A-Za-z0-9_-]+$ ]] || die 'fingerprint 格式不正确'

OUT='A-chain.json'
read -r -p "输出文件路径 [$OUT]: " INPUT_OUT
OUT="${INPUT_OUT:-$OUT}"

[[ ! -e "$OUT" ]] || die "文件已存在，不覆盖：$OUT"

cat > "$OUT" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "in-vless-reality",
      "listen": "0.0.0.0",
      "listen_port": $A_PORT,
      "users": [
        {
          "name": "client",
          "uuid": "$A_UUID",
          "flow": "$A_FLOW"
        }
      ],
      "tls": {
        "enabled": true,
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$A_SNI",
            "server_port": $A_HANDSHAKE_PORT
          },
          "private_key": "$A_PRIVATE_KEY",
          "short_id": ["$A_SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "to-B",
      "server": "$B_ADDRESS",
      "server_port": $B_PORT,
      "uuid": "$B_UUID",
      "flow": "$B_FLOW",
      "tls": {
        "enabled": true,
        "server_name": "$B_SNI",
        "utls": {
          "enabled": true,
          "fingerprint": "$FINGERPRINT"
        },
        "reality": {
          "enabled": true,
          "public_key": "$B_PUBLIC_KEY",
          "short_id": "$B_SHORT_ID"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "to-B"
  }
}
EOF

printf '\n已生成：%s\n' "$OUT"
printf '此脚本只生成文件，不会读取原配置、部署文件或重启服务。\n'
