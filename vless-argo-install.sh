#!/bin/bash
# vless + Cloudflare Argo Tunnel 一键脚本（sing-box + cloudflared）
# ============================================================================
# 用法：
#   bash vless-argo-install.sh -d your.domain.com -t '你的 Argo Token'
#   bash vless-argo-install.sh -d your.domain.com          # 不带 token 时会隐藏输入提示
#   bash vless-argo-install.sh -d your.domain.com -t 'TOKEN' \
#       -u 11111111-2222-3333-4444-555555555555 -w /my-path -p 8001
#
# 可选参数：
#   -d DOMAIN   自定义域名（必填，可交互输入）。必须是已接入 Cloudflare 的域名。
#   -t TOKEN    Argo Tunnel Token（可用环境变量 ARGO_AUTH 代替，缺省时隐藏输入）
#   -u UUID     客户端 UUID，缺省自动生成
#   -w PATH     WebSocket 路径，缺省 /vless-argo
#   -p PORT     本地监听端口，缺省 8001（只监听 127.0.0.1，不对外暴露）
#   --install-dir DIR   安装目录，缺省 /opt/vless-argo
#   --no-systemd        不写 systemd，改用 start.sh / stop.sh 手动启停
#   --dry-run           只生成配置和客户端链接到 ./vless-argo-out，不下载、不装服务、不启动
#   -h / --help         显示帮助
#
# 在 Cloudflare 端必须先做的一步（脚本代替不了）：
#   Zero Trust -> Networks -> Tunnels -> 建一个 Tunnel -> 复制它的 Token
#   -> Add public hostname：域名填 -d 的域名，Service 填 http://localhost:8001
#   （端口要和 -p 一致；Service 用 http，不是 https，因为本地就是明文监听）
#   域名解析不用你手动加：Tunnel 的 hostname 路由建好后，Cloudflare 会自动处理。
#
# 部署后客户端链接（脚本结束时也会打印并写入 client.txt）：
#   vless://UUID@域名:443?encryption=none&security=tls&sni=域名&type=ws&host=域名&path=/路径#名字
#
# 注意：
#   - 本脚本只从官方 GitHub 下载 sing-box 和 cloudflared，不经过任何第三方中转。
#   - Token 只写进安装目录下的 .env（600 权限），脚本运行过程不会把它打印出来。
#   - 这台机器如果会定时暂停/关机（例如 Instabox 免费版：闲置 30 分钟自动暂停、
#     最长运行 480 分钟），节点也会跟着停，那是平台限制，不是脚本问题，
#     长期跑节点请用不会自动暂停的 VPS。
# ============================================================================
set -euo pipefail

DOMAIN=""
TOKEN="${ARGO_AUTH:-}"
UUID_ARG=""
WS_PATH="/vless-argo"
LOCAL_PORT="8001"
INSTALL_DIR="/opt/vless-argo"
USE_SYSTEMD=1
DRY_RUN=0

usage() {
    sed -n '2,35p' "$0"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d) DOMAIN="${2:-}"; shift 2 ;;
        -t) TOKEN="${2:-}"; shift 2 ;;
        -u) UUID_ARG="${2:-}"; shift 2 ;;
        -w) WS_PATH="${2:-}"; shift 2 ;;
        -p) LOCAL_PORT="${2:-}"; shift 2 ;;
        --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
        --no-systemd) USE_SYSTEMD=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage ;;
        *) echo "未知参数：$1，用 -h 看用法" >&2; exit 1 ;;
    esac
done

# ---- 交互补齐必填项 ----
if [ -z "$DOMAIN" ]; then
    printf '域名（例如 node.example.com）：'
    read -r DOMAIN
fi
if [ -z "$TOKEN" ] && [ "$DRY_RUN" -eq 0 ]; then
    printf 'Argo Token（输入时不回显）：'
    read -rs TOKEN
    echo
fi
if [ "$DRY_RUN" -eq 1 ] && [ -z "$TOKEN" ]; then
    TOKEN="YOUR_ARGO_TOKEN_HERE"
fi
[ -n "$DOMAIN" ] || { echo "错误：域名不能为空" >&2; exit 1; }
[ -n "$TOKEN" ] || { echo "错误：Argo Token 不能为空" >&2; exit 1; }

# ---- 规范化 ----
case "$WS_PATH" in
    /*) ;;
    *) WS_PATH="/$WS_PATH" ;;
esac
case "$LOCAL_PORT" in
    ''|*[!0-9]*) echo "错误：端口必须是数字" >&2; exit 1 ;;
esac

if [ -n "$UUID_ARG" ]; then
    CLIENT_UUID="$UUID_ARG"
elif [ -r /proc/sys/kernel/random/uuid ]; then
    CLIENT_UUID="$(cat /proc/sys/kernel/random/uuid)"
else
    CLIENT_UUID="$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || echo '11111111-2222-3333-4444-555555555555')"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    INSTALL_DIR="./vless-argo-out"
fi

# 路径编码：/vless-argo -> %2Fvless-argo，供客户端链接 path 参数用
WS_PATH_ENC="%2F${WS_PATH#/}"
NODE_NAME="vless-argo"
CLIENT_LINK="vless://${CLIENT_UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WS_PATH_ENC}#${NODE_NAME}"

mkdir -p "$INSTALL_DIR"

# ---- 写 sing-box 配置 ----
cat > "$INSTALL_DIR/config.json" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "127.0.0.1",
      "listen_port": ${LOCAL_PORT},
      "users": [
        { "uuid": "${CLIENT_UUID}", "flow": "" }
      ],
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}",
        "max_early_data": 2560,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF

# ---- 写 .env（只含 Token，600 权限）----
printf 'ARGO_AUTH=%s\n' "$TOKEN" > "$INSTALL_DIR/.env"
chmod 600 "$INSTALL_DIR/.env"

# ---- 写启停脚本 ----
cat > "$INSTALL_DIR/run-cloudflared.sh" <<'EOS'
#!/bin/bash
cd "$(dirname "$0")"
set -a; source ./.env; set +a
exec ./cloudflared tunnel --no-autoupdate run --token "$ARGO_AUTH"
EOS
chmod +x "$INSTALL_DIR/run-cloudflared.sh"

cat > "$INSTALL_DIR/start.sh" <<'EOS'
#!/bin/bash
cd "$(dirname "$0")"
./sing-box check -c ./config.json || exit 1
nohup ./sing-box run -c ./config.json > singbox.log 2>&1 &
echo "sing-box 已启动 (PID $!)"
nohup ./run-cloudflared.sh > cloudflared.log 2>&1 &
echo "cloudflared 已启动 (PID $!)"
echo "等 20 秒后看 cloudflared.log 里出现 'Registered tunnel connection' 即表示隧道已通"
EOS
chmod +x "$INSTALL_DIR/start.sh"

cat > "$INSTALL_DIR/stop.sh" <<'EOS'
#!/bin/bash
cd "$(dirname "$0")"
pkill -f "vless-argo/sing-box run" 2>/dev/null || true
pkill -f "vless-argo/cloudflared tunnel" 2>/dev/null || true
echo "已停止"
EOS
chmod +x "$INSTALL_DIR/stop.sh"

printf '%s\n' "$CLIENT_LINK" > "$INSTALL_DIR/client.txt"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "dry-run 完成，文件在 $INSTALL_DIR（未下载、未装服务、未启动）"
    echo "客户端链接：$CLIENT_LINK"
    exit 0
fi

# ---- 下载官方二进制 ----
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64) SB_ARCH="amd64"; CF_ARCH="amd64" ;;
    aarch64|arm64) SB_ARCH="arm64"; CF_ARCH="arm64" ;;
    *) echo "错误：不支持的架构 $ARCH" >&2; exit 1 ;;
esac

if [ ! -x "$INSTALL_DIR/sing-box" ]; then
    SB_VER="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*: "\(.*\)".*/\1/' || true)"
    [ -n "$SB_VER" ] || SB_VER="v1.14.2"
    echo "下载 sing-box $SB_VER ..."
    curl -fsSL -o /tmp/sing-box.tar.gz \
        "https://github.com/SagerNet/sing-box/releases/download/${SB_VER}/sing-box-${SB_VER#v}-linux-${SB_ARCH}.tar.gz"
    tar xzf /tmp/sing-box.tar.gz -C /tmp
    cp "/tmp/sing-box-${SB_VER#v}-linux-${SB_ARCH}/sing-box" "$INSTALL_DIR/sing-box"
    chmod +x "$INSTALL_DIR/sing-box"
    rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${SB_VER#v}-linux-${SB_ARCH}"
fi

if [ ! -x "$INSTALL_DIR/cloudflared" ]; then
    echo "下载 cloudflared ..."
    curl -fsSL -o "$INSTALL_DIR/cloudflared" \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
    chmod +x "$INSTALL_DIR/cloudflared"
fi

"$INSTALL_DIR/sing-box" check -c "$INSTALL_DIR/config.json"

# ---- 启动 ----
if [ "$USE_SYSTEMD" -eq 1 ] && [ -d /run/systemd/system ] && [ "$(id -u)" -eq 0 ]; then
    cat > /etc/systemd/system/vless-argo-singbox.service <<EOF
[Unit]
Description=sing-box vless-argo
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${INSTALL_DIR}/sing-box run -c ${INSTALL_DIR}/config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/vless-argo-cloudflared.service <<EOF
[Unit]
Description=cloudflared vless-argo
After=network-online.target vless-argo-singbox.service
Wants=network-online.target

[Service]
ExecStart=${INSTALL_DIR}/run-cloudflared.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now vless-argo-singbox vless-argo-cloudflared
    sleep 8
    echo "--- sing-box 状态 ---"
    systemctl --no-pager status vless-argo-singbox | head -5 || true
    echo "--- cloudflared 日志（找 Registered tunnel connection）---"
    journalctl -u vless-argo-cloudflared --no-pager -n 20 2>/dev/null | tail -20 || true
else
    if [ "$USE_SYSTEMD" -eq 1 ]; then
        echo "提示：没有 systemd 或不是 root，改用 start.sh 手动启停"
    fi
    (cd "$INSTALL_DIR" && ./start.sh)
    sleep 20
    grep -h "Registered tunnel connection" "$INSTALL_DIR/cloudflared.log" 2>/dev/null \
        && echo "隧道已注册成功" \
        || echo "警告：cloudflared.log 里还没看到 Registered tunnel connection，请先确认 Cloudflare 端的 hostname 已建好，再看日志排查"
fi

echo
echo "完成。客户端链接（也已写入 $INSTALL_DIR/client.txt）："
echo "$CLIENT_LINK"
echo
echo "参数：域名=$DOMAIN，本地端口=$LOCAL_PORT，WS 路径=$WS_PATH，UUID=$CLIENT_UUID"
echo "换域名：改 Cloudflare 端 hostname 后，用新域名重新跑一遍本脚本即可（会覆盖配置并重启）"
