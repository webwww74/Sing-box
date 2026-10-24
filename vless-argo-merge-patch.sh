#!/bin/bash
# vless + Argo 融合补丁（给已经装好的四合一 sing-box 加一个 vless-Argo 节点）
# ============================================================================
# 这不是那份测试脚本的完整复制版，也不是在它原文件里改出来的版本。
# 它是一个独立的补丁，只做一件事：在已经装好的 sing-box 配置里，
# 加一个 vless + WebSocket 入站，走你自己的 Argo 自定义域名，本地端口 8002。
#
# 适用前提（缺一不可，先对一下）：
#   1. 服务器上已经用那份四合一脚本装好 sing-box，配置在 /etc/sing-box/config.json，
#      服务名是 sing-box 和 argo，vmess 已经占了本地 8001。
#   2. 你已经在 Cloudflare 有固定隧道（不是临时隧道），或者愿意按下面第 3 步去建。
#      临时隧道只转发到 8001，带不动第二个端口，补丁跑了链接也不会通。
#   3. 自定义域名已经在 Cloudflare 侧准备好：
#      - 如果域名和原来 vmess 的域名不一样：在 Tunnel 里加一条 public hostname，
#        域名填 -d 的域名，Service 填 http://localhost:8002。
#      - 如果域名和原来 vmess 的域名是同一个：不要再加一条同名 hostname，
#        补丁会在本地 tunnel.yml 里按路径分流（见下面），仪表盘托管的隧道则要在
#        仪表盘里给同名 hostname 加一条带路径 /vless-argo 的规则，指向 8002。
#
# 用法（在服务器上用 root 跑）：
#   bash vless-argo-merge-patch.sh -d 你的域名
#   bash vless-argo-merge-patch.sh -d 你的域名 -p 8002 -w /vless-argo
#   bash vless-argo-merge-patch.sh -d 你的域名 -u 你的UUID
#
# 参数：
#   -d DOMAIN         自定义域名（必填）
#   -p PORT           vless-Argo 本地端口，默认 8002（不要和已有的 8001、vless、hy2、tuic 撞）
#   -w PATH           WebSocket 路径，默认 /vless-argo
#   -u UUID           不给就沿用配置里已有的 UUID（四合一里各协议本来就是同一个 UUID）
#   --config PATH     sing-box 配置文件，默认 /etc/sing-box/config.json
#   --tunnel-yml PATH 本地隧道配置文件，默认 /etc/sing-box/tunnel.yml（没有就跳过）
#   --url-file PATH   节点链接文件，默认 /etc/sing-box/url.txt（没有就跳过）
#   --no-restart      只改文件，不重启 sing-box / argo 服务（测试、演练时用）
#   -h, --help        显示帮助
#
# 补丁会做的事（都会先备份，原文件加 .bak.时间戳后缀）：
#   1. 在 config.json 里加（或更新）一个入站：tag=vless-argo，type=vless，
#      listen=127.0.0.1，listen_port=8002，transport=ws，path=/vless-argo，无 TLS
#      （TLS 由 Cloudflare 在边缘终结，本地就是明文，和原来 vmess 的做法一样）。
#   2. 如果 tunnel.yml 存在：域名没出现过，就加一条 hostname -> http://localhost:8002；
#      域名已经出现过（和 vmess 同名），就在 ingress 开头加一条带 path 的规则，
#      让 /vless-argo 走 8002，其它路径仍走原来的 8001。
#   3. 在 url.txt 末尾加（或更新）一条 vless 链接，并重新生成 sub.txt（如果 url.txt 存在）。
#   4. 重启 sing-box 和 argo 服务（除非 --no-restart）。
#
# 补丁不会做的事：
#   - 不下载任何二进制，不改原来四个协议，不删原来任何入站，不碰 Cloudflare 仪表盘。
#   - 不把你的 Token 写进任何文件：固定隧道本来就已经在服务器上配好了，补丁不问 Token。
#   - 重复跑不会重复加入站、不会重复加链接，第二次跑就是更新。
#
# 客户端链接格式（跑完会打印）：
#   vless://UUID@域名:443?encryption=none&security=tls&sni=域名&type=ws&host=域名&path=%2Fvless-argo#vless-argo
# ============================================================================
set -euo pipefail

DOMAIN=""
LOCAL_PORT="8002"
WS_PATH="/vless-argo"
UUID_ARG=""
CONFIG_FILE="/etc/sing-box/config.json"
TUNNEL_YML="/etc/sing-box/tunnel.yml"
URL_FILE="/etc/sing-box/url.txt"
NO_RESTART=0

usage() {
    sed -n '2,50p' "$0"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d) DOMAIN="${2:-}"; shift 2 ;;
        -p) LOCAL_PORT="${2:-}"; shift 2 ;;
        -w) WS_PATH="${2:-}"; shift 2 ;;
        -u) UUID_ARG="${2:-}"; shift 2 ;;
        --config) CONFIG_FILE="${2:-}"; shift 2 ;;
        --tunnel-yml) TUNNEL_YML="${2:-}"; shift 2 ;;
        --url-file) URL_FILE="${2:-}"; shift 2 ;;
        --no-restart) NO_RESTART=1; shift ;;
        -h|--help) usage ;;
        *) echo "未知参数：$1，用 -h 看用法" >&2; exit 1 ;;
    esac
done

if [ -z "$DOMAIN" ]; then
    printf '自定义域名（例如 vless.example.com）：'
    read -r DOMAIN
fi
[ -n "$DOMAIN" ] || { echo "错误：域名不能为空" >&2; exit 1; }
case "$WS_PATH" in
    /*) ;;
    *) WS_PATH="/$WS_PATH" ;;
esac
case "$LOCAL_PORT" in
    ''|*[!0-9]*) echo "错误：端口必须是数字" >&2; exit 1 ;;
esac
[ -f "$CONFIG_FILE" ] || { echo "错误：找不到配置文件 $CONFIG_FILE，请确认四合一已经装好，或用 --config 指定" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "错误：需要 python3（用来安全地改 JSON，不用 sed 硬改）" >&2; exit 1; }

TS="$(date +%Y%m%d%H%M%S)"
cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$TS"
echo "已备份配置：$CONFIG_FILE.bak.$TS"

# ---- 用 python3 改 JSON：沿用已有 UUID，删掉旧的 vless-argo 再加新的 ----
CLIENT_UUID="$(UUID_ARG="$UUID_ARG" CONFIG_FILE="$CONFIG_FILE" LOCAL_PORT="$LOCAL_PORT" WS_PATH="$WS_PATH" python3 - <<'PYEOF'
import json, os, sys, uuid
config_file = os.environ["CONFIG_FILE"]
port = int(os.environ["LOCAL_PORT"])
ws_path = os.environ["WS_PATH"]
uuid_arg = os.environ["UUID_ARG"]
with open(config_file) as f:
    data = json.load(f)
inbounds = data.get("inbounds", [])
found = ""
for inbound in inbounds:
    for user in inbound.get("users", []) or []:
        if user.get("uuid"):
            found = user["uuid"]
            break
    if found:
        break
    if inbound.get("type") == "hysteria2":
        for user in inbound.get("users", []) or []:
            if user.get("password"):
                found = user["password"]
                break
    if found:
        break
client_uuid = uuid_arg or found or str(uuid.uuid4())
inbounds = [i for i in inbounds if i.get("tag") != "vless-argo"]
inbounds.append({
    "type": "vless",
    "tag": "vless-argo",
    "listen": "127.0.0.1",
    "listen_port": port,
    "users": [{"uuid": client_uuid, "flow": ""}],
    "transport": {
        "type": "ws",
        "path": ws_path,
        "max_early_data": 2560,
        "early_data_header_name": "Sec-WebSocket-Protocol",
    },
})
data["inbounds"] = inbounds
with open(config_file, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(client_uuid)
PYEOF
)"

WS_PATH_ENC="%2F${WS_PATH#/}"
CLIENT_LINK="vless://${CLIENT_UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WS_PATH_ENC}#vless-argo"
echo "vless-Argo 入站已写入：127.0.0.1:$LOCAL_PORT，路径 $WS_PATH，UUID $CLIENT_UUID"

# ---- 本地 tunnel.yml（如果存在）按域名是否已出现，分两种方式加规则 ----
if [ -f "$TUNNEL_YML" ]; then
    cp "$TUNNEL_YML" "$TUNNEL_YML.bak.$TS"
    echo "已备份隧道配置：$TUNNEL_YML.bak.$TS"
    DOMAIN="$DOMAIN" LOCAL_PORT="$LOCAL_PORT" WS_PATH="$WS_PATH" TUNNEL_YML="$TUNNEL_YML" python3 - <<'PYEOF'
import os
yml_path = os.environ["TUNNEL_YML"]
domain = os.environ["DOMAIN"]
port = os.environ["LOCAL_PORT"]
ws_path = os.environ["WS_PATH"]
with open(yml_path) as f:
    text = f.read()
if f"hostname: {domain}" in text:
    # 同名域名：只在 ingress 开头加一条带 path 的规则，先匹配 vless，再落到原来的规则
    path_rule = f"  - hostname: {domain}\n    path: {ws_path}\n    service: http://localhost:{port}\n"
    if path_rule.strip() not in text:
        lines = text.splitlines(True)
        out = []
        inserted = False
        for line in lines:
            out.append(line)
            if not inserted and line.strip() == "ingress:":
                out.append(path_rule)
                inserted = True
        if not inserted:
            out.append(path_rule)
        text = "".join(out)
        print("隧道配置：同名域名，已加带路径的分流规则（/vless-argo -> 8002）")
    else:
        print("隧道配置：带路径的规则已经存在，不重复加")
else:
    new_rule = f"  - hostname: {domain}\n    service: http://localhost:{port}\n"
    fallback = "  - service: http_status:404"
    if fallback in text:
        text = text.replace(fallback, new_rule + fallback, 1)
    else:
        if not text.endswith("\n"):
            text += "\n"
        text += new_rule
    print(f"隧道配置：已加新 hostname {domain} -> http://localhost:{port}")
with open(yml_path, "w") as f:
    f.write(text)
PYEOF
else
    echo "注意：没有找到本地 $TUNNEL_YML，说明你的隧道可能是仪表盘托管（Token 模式）或临时隧道。"
    echo "请在 Cloudflare 仪表盘里手动加一条 public hostname：域名=$DOMAIN，Service=http://localhost:$LOCAL_PORT"
    echo "如果域名和原来 vmess 的域名相同，仪表盘里要给同名 hostname 加一条带路径 $WS_PATH 的规则，指向 $LOCAL_PORT，不要再加一条同名无路径规则。"
fi

# ---- 更新 url.txt 和 sub.txt（如果存在）----
if [ -f "$URL_FILE" ]; then
    cp "$URL_FILE" "$URL_FILE.bak.$TS" 2>/dev/null || true
    grep -v '#vless-argo$' "$URL_FILE" > "$URL_FILE.tmp" || true
    mv "$URL_FILE.tmp" "$URL_FILE"
    printf '%s\n' "$CLIENT_LINK" >> "$URL_FILE"
    base64 -w0 "$URL_FILE" > "$(dirname "$URL_FILE")/sub.txt" 2>/dev/null || base64 "$URL_FILE" | tr -d '\n' > "$(dirname "$URL_FILE")/sub.txt" || true
    echo "链接已写入：$URL_FILE"
fi

# ---- 重启服务 ----
if [ "$NO_RESTART" -eq 1 ]; then
    echo "已跳过重启（--no-restart），请手动重启 sing-box 和 argo 后再测试。"
else
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart sing-box 2>/dev/null || echo "提示：sing-box 服务重启失败或不存在，请手动检查"
        systemctl restart argo 2>/dev/null || echo "提示：argo 服务重启失败或不存在，请手动检查"
    else
        echo "提示：没有 systemctl，请手动重启 sing-box 和 argo"
    fi
fi

echo
echo "完成。客户端链接："
echo "$CLIENT_LINK"
echo
echo "参数：域名=$DOMAIN，本地端口=$LOCAL_PORT，WS 路径=$WS_PATH"
echo "测试前请确认：Cloudflare 侧的 hostname/Service（或路径规则）已经指向 $LOCAL_PORT，否则隧道通、节点还是不通——上次就是 8001/8002 对不上闹的。"
