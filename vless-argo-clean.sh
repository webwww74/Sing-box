#!/bin/bash
# vless + Cloudflare Argo Tunnel，干净独立版
# ============================================================================
# 这是一个从零写的独立脚本，不含任何第三方一键脚本的代码，
# 不装 nginx、不装订阅转换、不做系统升级、不装其它协议，只做一件事：
#   sing-box（本地 vless + WebSocket）+ cloudflared（Argo 隧道）-> 你的自定义域名
#
# 下载来源只有两个官方地址，不走任何第三方镜像：
#   github.com/SagerNet/sing-box
#   github.com/cloudflare/cloudflared
#
# 用法：
#   bash vless-argo-clean.sh                        # 不带参数直接进选择菜单
#   bash vless-argo-clean.sh --menu                 # 同上
#   bash vless-argo-clean.sh -d 你的域名 -t '你的 Argo Token'
#   bash vless-argo-clean.sh -d 你的域名            # 不带 token 时隐藏输入
#   bash vless-argo-clean.sh -d 你的域名 -t 'TOKEN' \
#       -u 11111111-2222-3333-4444-555555555555 -w /vless -p 8002
#
# 选择菜单（不带参数或 --menu 时出现）：
#   1 安装 / 重装（含换域名：用新域名重装即可）
#   2 卸载
#   3 重新启动 argo（只重启 cloudflared，不动 sing-box）
#   4 查看状态
#   0 退出
#
# 参数：
#   -d DOMAIN         自定义域名（必填）。必须是已接入 Cloudflare 的域名。
#   -t TOKEN          Argo Token，也可用环境变量 ARGO_AUTH 代替
#   -u UUID           客户端 UUID，不给就自动生成
#   -w PATH           WebSocket 路径，默认 /vless-argo
#   -p PORT           本地监听端口，默认 8002，只监听 127.0.0.1，不对外暴露
#   --install-dir DIR 安装目录，默认 /opt/vless-argo-clean
#   --no-systemd      不写 systemd，改用安装目录下的 start.sh / stop.sh
#   --dry-run         只生成配置和客户端链接到 ./vless-argo-clean-out，
#                     不下载、不装服务、不启动
#   --status          查看运行状态和客户端链接
#   --restart-argo    只重启 cloudflared（不重启 sing-box）
#   --menu            显示选择菜单（不带参数时默认就是菜单）
#   --uninstall [--force]  停止并删除本脚本装的东西
#   -h, --help        显示帮助
#
# 在 Cloudflare 端必须先做的一步（脚本代替不了）：
#   Zero Trust -> Networks -> Tunnels -> 建一个 Tunnel -> 复制 Token
#   -> Add public hostname：域名填 -d 的域名，Service 填 http://localhost:8002
#   （端口要和 -p 一致；Service 用 http，因为本地就是明文监听；
#    Tunnel 建好 hostname 后，域名解析由 Cloudflare 自动处理，不用你手动加 DNS）
#
# 客户端链接格式（脚本结束时打印，也写入 client.txt）：
#   vless://UUID@域名:443?encryption=none&security=tls&sni=域名&type=ws&host=域名&path=%2Fvless-argo#vless-argo
#
# 安全说明：
#   - Token 只写进安装目录下的 .env，权限 600，脚本不会把它打印到屏幕或链接里。
#   - 本地只监听 127.0.0.1，公网流量只能经 Cloudflare 隧道进来。
#   - 别在这台 Muse 沙箱机器上跑：它出站被拦，隧道注册不上。
#     也别指望会自动暂停的免费云电脑长期跑节点（例如闲置自动暂停的机器）。
# ============================================================================
set -euo pipefail

DOMAIN=""
TOKEN="${ARGO_AUTH:-}"
UUID_ARG=""
WS_PATH="/vless-argo"
LOCAL_PORT="8002"
INSTALL_DIR="/opt/vless-argo-clean"
USE_SYSTEMD=1
DRY_RUN=0
FORCE=0
ACTION="install"
SHOW_MENU=0
# 不带任何参数时默认进菜单；带参数走原来的命令行方式，不被菜单打断
[ $# -eq 0 ] && SHOW_MENU=1

usage() {
    sed -n '2,/^# ===/p' "$0"
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
        --status) ACTION="status"; shift ;;
        --restart-argo) ACTION="restart-argo"; shift ;;
        --menu) SHOW_MENU=1; shift ;;
        --uninstall) ACTION="uninstall"; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage ;;
        *) echo "未知参数：$1，用 -h 看用法" >&2; exit 1 ;;
    esac
done

# ---- 选择菜单：不带参数或 --menu 时出现；带 -d 等参数时不出现 ----
if [ "$SHOW_MENU" -eq 1 ] && [ "$ACTION" = "install" ]; then
    echo "vless-argo-clean 选择菜单"
    echo "  1) 安装 / 重装（含换域名）"
    echo "  2) 卸载"
    echo "  3) 重新启动 argo（只重启 cloudflared，不动 sing-box）"
    echo "  4) 查看状态"
    echo "  0) 退出"
    printf '请选择 [0-4]：'
    read -r choice
    case "$choice" in
        1)
            printf '域名（例如 vless.example.com）：'
            read -r DOMAIN
            if [ -z "$TOKEN" ] && [ "$DRY_RUN" -eq 0 ]; then
                printf 'Argo Token（输入时不回显，留空则用环境变量 ARGO_AUTH）：'
                read -rs TOKEN
                echo
            fi
            printf 'UUID（留空自动生成；重装想保持原链接就填原 UUID）：'
            read -r UUID_ARG
            printf 'WS 路径（留空默认 /vless-argo）：'
            read -r input_path
            [ -n "$input_path" ] && WS_PATH="$input_path"
            printf '本地端口（留空默认 8002）：'
            read -r input_port
            [ -n "$input_port" ] && LOCAL_PORT="$input_port"
            ;;
        2) ACTION="uninstall" ;;
        3) ACTION="restart-argo" ;;
        4) ACTION="status" ;;
        0) echo "已退出"; exit 0 ;;
        *) echo "无效选择：$choice" >&2; exit 1 ;;
    esac
fi

# ---- 只重启 argo：不动 sing-box，只重启 cloudflared ----
if [ "$ACTION" = "restart-argo" ]; then
    if [ -f /etc/systemd/system/vless-argo-clean-cloudflared.service ] && [ -d /run/systemd/system ]; then
        systemctl restart vless-argo-clean-cloudflared
        sleep 3
        systemctl --no-pager is-active vless-argo-clean-cloudflared
        echo "argo 已重启（systemd）"
    elif [ -x "$INSTALL_DIR/run-cloudflared.sh" ]; then
        # 非 systemd（例如 Alpine）方式：只杀 cwd 在本安装目录的 cloudflared，
        # 不碰四合一的 /etc/sing-box/argo，也不碰 sing-box
        for pid in $(pgrep -f cloudflared 2>/dev/null || true); do
            if [ -r "/proc/$pid/cwd" ] && [ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" = "$INSTALL_DIR" ]; then
                kill "$pid" 2>/dev/null || true
            fi
        done
        sleep 2
        (cd "$INSTALL_DIR" && nohup ./run-cloudflared.sh > cloudflared.log 2>&1 &)
        echo "argo 已重启（nohup），新进程日志在 $INSTALL_DIR/cloudflared.log"
        sleep 5
        grep -h "Registered tunnel connection" "$INSTALL_DIR/cloudflared.log" 2>/dev/null \
            && echo "隧道已重新注册成功" \
            || echo "提示：日志里还没看到 Registered tunnel connection，请先确认 Cloudflare 端 hostname 已建好，再看 cloudflared.log"
    else
        echo "错误：找不到已安装的 argo（$INSTALL_DIR/run-cloudflared.sh 不存在），请先选 1 安装" >&2
        exit 1
    fi
    exit 0
fi

# ---- 状态查看：不需要域名和 Token ----
if [ "$ACTION" = "status" ]; then
    echo "安装目录：$INSTALL_DIR"
    if [ -f "$INSTALL_DIR/client.txt" ]; then
        echo "客户端链接："
        cat "$INSTALL_DIR/client.txt"
    else
        echo "还没有 client.txt，可能尚未安装。"
    fi
    if [ -f /etc/systemd/system/vless-argo-clean-singbox.service ]; then
        systemctl --no-pager status vless-argo-clean-singbox vless-argo-clean-cloudflared 2>/dev/null | head -30 || true
    else
        pgrep -af "vless-argo-clean/sing-box run" || echo "sing-box 未在运行"
        pgrep -af "vless-argo-clean/cloudflared" || echo "cloudflared 未在运行"
    fi
    exit 0
fi

# ---- 卸载 ----
if [ "$ACTION" = "uninstall" ]; then
    if [ "$FORCE" -eq 0 ]; then
        printf '确认删除 %s 及两个 systemd 服务吗？输入 yes 继续：' "$INSTALL_DIR"
        read -r answer
        [ "$answer" = "yes" ] || { echo "已取消"; exit 0; }
    fi
    # 先停 nohup 方式起的进程（--no-systemd 时没有 systemd 服务可停，只靠这一步）
    if [ -x "$INSTALL_DIR/stop.sh" ]; then "$INSTALL_DIR/stop.sh" 2>/dev/null || true; fi
    pkill -f "$INSTALL_DIR/sing-box run" 2>/dev/null || true
    pkill -f "$INSTALL_DIR/cloudflared" 2>/dev/null || true
    pkill -f "$INSTALL_DIR/run-cloudflared.sh" 2>/dev/null || true
    systemctl stop vless-argo-clean-singbox vless-argo-clean-cloudflared 2>/dev/null || true
    systemctl disable vless-argo-clean-singbox vless-argo-clean-cloudflared 2>/dev/null || true
    rm -f /etc/systemd/system/vless-argo-clean-singbox.service /etc/systemd/system/vless-argo-clean-cloudflared.service
    systemctl daemon-reload 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    echo "已卸载：$INSTALL_DIR"
    exit 0
fi

# ---- 交互补齐必填项 ----
if [ -z "$DOMAIN" ]; then
    printf '域名（例如 vless.example.com）：'
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
    INSTALL_DIR="./vless-argo-clean-out"
fi

WS_PATH_ENC="%2F${WS_PATH#/}"
CLIENT_LINK="vless://${CLIENT_UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WS_PATH_ENC}#vless-argo"

mkdir -p "$INSTALL_DIR"

cat > "$INSTALL_DIR/config.json" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-argo",
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

printf 'ARGO_AUTH=%s\n' "$TOKEN" > "$INSTALL_DIR/.env"
chmod 600 "$INSTALL_DIR/.env"

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
pkill -f "vless-argo-clean/sing-box run" 2>/dev/null || true
pkill -f "vless-argo-clean/cloudflared" 2>/dev/null || true
echo "已停止"
EOS
chmod +x "$INSTALL_DIR/stop.sh"

printf '%s\n' "$CLIENT_LINK" > "$INSTALL_DIR/client.txt"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "dry-run 完成，文件在 $INSTALL_DIR（未下载、未装服务、未启动）"
    echo "客户端链接：$CLIENT_LINK"
    exit 0
fi

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
    echo "下载 sing-box $SB_VER（官方 GitHub）..."
    curl -fsSL -o /tmp/sing-box.tar.gz \
        "https://github.com/SagerNet/sing-box/releases/download/${SB_VER}/sing-box-${SB_VER#v}-linux-${SB_ARCH}.tar.gz"
    tar xzf /tmp/sing-box.tar.gz -C /tmp
    cp "/tmp/sing-box-${SB_VER#v}-linux-${SB_ARCH}/sing-box" "$INSTALL_DIR/sing-box"
    chmod +x "$INSTALL_DIR/sing-box"
    rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${SB_VER#v}-linux-${SB_ARCH}"
fi

if [ ! -x "$INSTALL_DIR/cloudflared" ]; then
    echo "下载 cloudflared（官方 GitHub）..."
    curl -fsSL -o "$INSTALL_DIR/cloudflared" \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
    chmod +x "$INSTALL_DIR/cloudflared"
fi

"$INSTALL_DIR/sing-box" check -c "$INSTALL_DIR/config.json"

if [ "$USE_SYSTEMD" -eq 1 ] && [ -d /run/systemd/system ] && [ "$(id -u)" -eq 0 ]; then
    cat > /etc/systemd/system/vless-argo-clean-singbox.service <<EOF
[Unit]
Description=sing-box vless-argo-clean
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${INSTALL_DIR}/sing-box run -c ${INSTALL_DIR}/config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/vless-argo-clean-cloudflared.service <<EOF
[Unit]
Description=cloudflared vless-argo-clean
After=network-online.target vless-argo-clean-singbox.service
Wants=network-online.target

[Service]
ExecStart=${INSTALL_DIR}/run-cloudflared.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now vless-argo-clean-singbox vless-argo-clean-cloudflared
    sleep 8
    journalctl -u vless-argo-clean-cloudflared --no-pager -n 20 2>/dev/null | tail -20 || true
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
