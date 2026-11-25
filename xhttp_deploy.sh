#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 颜色与日志函数
# ============================================================
log()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
step() { echo -e "\n\033[1;36m========== $* ==========\033[0m"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }

# ============================================================
# 检查 root 权限
# ============================================================
if [[ "${EUID}" -ne 0 ]]; then
    err "请使用 root 用户或 sudo 运行本脚本。"
    exit 1
fi

# ============================================================
# 菜单
# ============================================================
show_menu() {
    echo ""
    echo "============================================"
    echo "     Xray + Nginx + Certbot 管理脚本"
    echo "============================================"
    echo "  1) 安装并配置 (Nginx + Certbot + Xray)"
    echo "  2) 全部卸载 (清理所有组件与配置)"
    echo "  3) 查看当前 VLESS 链接"
    echo "  0) 退出"
    echo "============================================"
}

# ============================================================
# 安装流程
# ============================================================
do_install() {
    step "开始安装"

    step "[1/8] 安装 NGINX 与 Certbot"
    apt update
    apt install -y nginx certbot python3-certbot-nginx
    log "NGINX 与 Certbot 安装完成"

    step "[2/8] 替换默认静态网页"
    local WEB_ROOT="/var/www/html"
    mkdir -p "$WEB_ROOT"
    cd "$WEB_ROOT"
    [ -f index.nginx-debian.html ] && rm -f index.nginx-debian.html
    wget -q -O index.html "https://raw.githubusercontent.com/OnceSeeLight/xray-xhttp/refs/heads/main/index.html"
    log "已替换为新的 index.html"

    step "[3/8] 申请 SSL 证书"
    read -rp "请输入域名 (例如 example.com): " DOMAIN
    if [[ -z "${DOMAIN}" ]]; then
        err "域名不能为空，安装中止。"
        return 1
    fi
    if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        warn "检测到已存在 $DOMAIN 的证书，跳过申请。"
    else
        certbot certonly --nginx -d "$DOMAIN" \
            --non-interactive --agree-tos --register-unsafely-without-email
        log "SSL 证书申请完成"
    fi

    step "[4/8] 安装 Xray 并生成 UUID"
    if ! command -v xray >/dev/null 2>&1; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    else
        warn "Xray 已安装，跳过。"
    fi
    local UUID
    UUID=$(xray uuid)
    log "生成的 UUID: $UUID"

    step "[5/8] 下载 Xray 配置"
    local XRAY_CONFIG="/usr/local/etc/xray/config.json"
    mkdir -p "$(dirname "$XRAY_CONFIG")"
    wget -q -O "$XRAY_CONFIG" "https://raw.githubusercontent.com/OnceSeeLight/xray-xhttp/refs/heads/main/config.json"

    step "[6/8] 生成 6 位随机小写字符串"
    local RANDOM_STR
    RANDOM_STR=$(set +o pipefail; tr -dc 'a-z' < /dev/urandom | head -c 6)
    if [[ ${#RANDOM_STR} -ne 6 ]]; then
        err "随机字符串生成失败（长度 ${#RANDOM_STR}），请重试。"
        return 1
    fi
    log "生成的随机字符串: $RANDOM_STR"

    step "[7/8] 替换配置中的 UUID 与 /api/stream 路径"
    sed -i "s/YOUR_UUID_HERE/$UUID/g"        "$XRAY_CONFIG"
    sed -i "s|/api/stream|/api/$RANDOM_STR|g" "$XRAY_CONFIG"
    log "Xray 配置已写入: $XRAY_CONFIG"

        # ---------- 步骤 8: 配置 NGINX 站点（分步：先基础 HTTPS，再反向代理） ----------
        # ---------- 步骤 8: 配置 NGINX 站点（分步：先基础 HTTPS，再反向代理） ----------
    step "[8/8] 配置 NGINX 站点"
    local NGINX_AVAILABLE="/etc/nginx/sites-available"
    local NGINX_ENABLED="/etc/nginx/sites-enabled"
    mkdir -p "$NGINX_AVAILABLE" "$NGINX_ENABLED"

    # 下载两个配置文件
    wget -q -O "$NGINX_AVAILABLE/default_https"           "https://raw.githubusercontent.com/OnceSeeLight/xray-xhttp/refs/heads/main/default_https"
    wget -q -O "$NGINX_AVAILABLE/default_https_site_only" "https://raw.githubusercontent.com/OnceSeeLight/xray-xhttp/refs/heads/main/default_https_site_only"

    # 替换配置中的域名占位符（补充 yourdomain.com）
    for f in "$NGINX_AVAILABLE/default_https" "$NGINX_AVAILABLE/default_https_site_only"; do
        sed -i \
            -e "s/YOUR_DOMAIN_HERE/$DOMAIN/g" \
            -e "s/yourdomain\.com/$DOMAIN/g" \
            -e "s/example\.com/$DOMAIN/g" \
            "$f"
    done
    log "已替换配置中的域名占位符为: $DOMAIN"

    # 将 default_https 中的 /api/stream 替换为实际的 /api/$RANDOM_STR
    sed -i "s|/api/stream|/api/$RANDOM_STR|g" "$NGINX_AVAILABLE/default_https"
    log "已将 Nginx 反向代理路径替换为: /api/$RANDOM_STR"

    # ---------- 校验证书路径是否存在 ----------
    local CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
    if [[ ! -f "$CERT_DIR/fullchain.pem" ]] || [[ ! -f "$CERT_DIR/privkey.pem" ]]; then
        err "证书文件不存在: $CERT_DIR"
        err "请确认第 3 步 Certbot 是否成功为 $DOMAIN 申请了证书。"
        err "可手动检查: ls -l /etc/letsencrypt/live/"
        return 1
    fi
    log "证书路径校验通过: $CERT_DIR"

    # ============================================================
    # 阶段 A：基础 HTTPS（仅静态站，使用 site_only 配置）
    # ============================================================
    step "阶段 A：启用基础 HTTPS（仅静态站）"
    rm -f "$NGINX_ENABLED/default"
    rm -f "$NGINX_ENABLED/default_https"
    rm -f "$NGINX_ENABLED/default_https_site_only"
    ln -sf "$NGINX_AVAILABLE/default_https_site_only" "$NGINX_ENABLED/default"
    log "已启用 default_https_site_only（基础 HTTPS）"

    if nginx -t; then
        systemctl reload nginx
        log "阶段 A 完成：HTTPS 基础站点已生效，可访问 https://$DOMAIN 验证伪装页面"
    else
        err "阶段 A NGINX 配置验证失败，请检查 $NGINX_AVAILABLE/default_https_site_only"
        err "常见原因：证书路径错误、域名未替换、端口冲突"
        return 1
    fi

    # ============================================================
    # 阶段 B：反向代理（静态站 + /api/stream 转发到 Xray）
    # ============================================================
    step "阶段 B：启用反向代理（完整配置）"
    rm -f "$NGINX_ENABLED/default"
    ln -sf "$NGINX_AVAILABLE/default_https" "$NGINX_ENABLED/default"
    log "已替换为 default_https（含反向代理）"

    local DEFAULT_SERVER_COUNT=0
    while IFS= read -r _line; do
        DEFAULT_SERVER_COUNT=$((DEFAULT_SERVER_COUNT + 1))
    done < <(grep -rl "default_server" "$NGINX_ENABLED" 2>/dev/null || true)
    if [[ "$DEFAULT_SERVER_COUNT" -gt 1 ]]; then
        err "检测到 $DEFAULT_SERVER_COUNT 个配置文件包含 default_server，会导致冲突："
        grep -rl "default_server" "$NGINX_ENABLED" 2>/dev/null | sed 's/^/  - /'
        err "请只保留一个包含 default_server 的配置后重试。"
        return 1
    fi
    log "default_server 冲突检测通过（共 $DEFAULT_SERVER_COUNT 个）"

    if nginx -t; then
        systemctl reload nginx
        log "阶段 B 完成：反向代理已生效，/api/$RANDOM_STR → 127.0.0.1:8080"
    else
        err "阶段 B NGINX 配置验证失败，请检查 $NGINX_AVAILABLE/default_https"
        err "回滚到阶段 A 配置..."
        rm -f "$NGINX_ENABLED/default"
        ln -sf "$NGINX_AVAILABLE/default_https_site_only" "$NGINX_ENABLED/default"
        nginx -t && systemctl reload nginx && log "已回滚到基础 HTTPS 配置"
        return 1
    fi

    systemctl restart xray
    systemctl enable xray >/dev/null 2>&1 || true
    log "Xray 服务已重启"

    cat > /root/xray_env.sh <<EOF
export UUID="$UUID"
export DOMAIN="$DOMAIN"
export RANDOM_STR="$RANDOM_STR"
EOF
    chmod 600 /root/xray_env.sh
    log "已保存变量到 /root/xray_env.sh（DOMAIN=$DOMAIN）"

    step "安装完成"
    echo "域名      : $DOMAIN"
    echo "UUID      : $UUID"
    echo "Xray 路径 : /api/$RANDOM_STR"
    echo "Xray 配置 : $XRAY_CONFIG"
    echo "变量文件  : /root/xray_env.sh"
    echo "--------------------------------------------"

    # 安装完成后立即显示当前 VLESS 链接
    do_show_link
}

# ============================================================
# 卸载流程
# ============================================================
do_uninstall() {
    step "开始卸载"
    read -rp "确认要全部卸载吗？此操作不可恢复 (输入 yes 继续): " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        warn "已取消卸载。"
        return 0
    fi

    step "[1/6] 卸载 Xray"
    if command -v xray >/dev/null 2>&1; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge || true
    fi
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
    rm -rf /usr/local/etc/xray /usr/local/bin/xray /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
    systemctl daemon-reload || true
    log "Xray 已卸载"

    step "[2/6] 清理 NGINX 配置"
    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-enabled/default_https
    rm -f /etc/nginx/sites-enabled/default_https_site_only
    rm -f /etc/nginx/sites-available/default_https
    rm -f /etc/nginx/sites-available/default_https_site_only
    log "NGINX 站点配置已清理"

    step "[3/6] 清理静态网页"
    rm -f /var/www/html/index.html
    log "静态网页已清理"

    step "[4/6] 删除 SSL 证书"
    if [ -d /etc/letsencrypt ]; then
        read -rp "请输入要删除证书的域名 (留空则跳过): " DEL_DOMAIN
        if [[ -n "$DEL_DOMAIN" ]]; then
            certbot delete --cert-name "$DEL_DOMAIN" --non-interactive || warn "删除证书失败，请手动处理。"
        else
            warn "跳过证书删除。"
        fi
    fi

    step "[5/6] 卸载 NGINX 与 Certbot"
    systemctl stop nginx 2>/dev/null || true
    apt purge -y nginx nginx-common nginx-full certbot python3-certbot-nginx 2>/dev/null || true
    apt autoremove -y
    log "NGINX 与 Certbot 已卸载"

    step "[6/6] 清理辅助文件"
    rm -f /root/xray_env.sh /root/vless_link.txt
    log "辅助文件已清理"

    step "卸载完成"
    echo "所有相关组件与配置已清理。"
    echo "如需重新安装，请重新运行本脚本选择 1。"
}

# ============================================================
# 查看当前 VLESS 链接（只读，不修改任何配置）
# ============================================================
do_show_link() {
    step "查看当前 VLESS 链接"

    local XRAY_CONFIG="/usr/local/etc/xray/config.json"
    local UUID DOMAIN RANDOM_STR PORT REMARK IP PATH_RAW

    # ---------- 校验必要文件 ----------
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        err "未找到 Xray 配置: $XRAY_CONFIG"
        err "请先执行安装（菜单 1）。"
        return 1
    fi

    # ---------- 从 Xray 配置中读取 UUID ----------
    # 取第一个 "id": "xxxx" 作为 UUID
    UUID=$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' "$XRAY_CONFIG" \
           | head -n1 | sed -E 's/.*"([^"]+)"$/\1/') || true
    if [[ -z "${UUID:-}" ]]; then
        err "无法从 Xray 配置中解析出 UUID。"
        return 1
    fi

    # ---------- 从 Xray 配置中读取 /api/xxx 路径 ----------
    PATH_RAW=$(grep -oE '/api/[a-zA-Z0-9_-]+' "$XRAY_CONFIG" | head -n1) || true
    if [[ -z "${PATH_RAW:-}" ]]; then
        err "无法从 Xray 配置中解析出 /api/xxx 路径。"
        return 1
    fi
    RANDOM_STR="${PATH_RAW#/api/}"

    # ---------- 从 Nginx 配置中读取域名 ----------
        # ---------- 解析域名：优先用安装时保存的 DOMAIN ----------
    DOMAIN=""
    # 1. 优先读取 /root/xray_env.sh（安装时输入的真实域名）
    if [[ -f /root/xray_env.sh ]]; then
        # shellcheck disable=SC1091
        source /root/xray_env.sh
        log "已从 /root/xray_env.sh 加载域名: ${DOMAIN:-<空>}"
    fi
    # 2. 没有则从 Nginx 配置解析
    if [[ -z "${DOMAIN:-}" ]]; then
        for f in /etc/nginx/sites-available/default_https \
                 /etc/nginx/sites-available/default_https_site_only; do
            if [[ -f "$f" ]]; then
                DOMAIN=$(grep -oE 'server_name[[:space:]]+[^;]+;' "$f" \
                         | head -n1 | sed -E 's/server_name[[:space:]]+([^;]+);/\1/' \
                         | awk '{print $1}') || true
                [[ -n "$DOMAIN" ]] && break
            fi
        done
    fi
    # 3. 仍为空则回退证书目录
    if [[ -z "${DOMAIN:-}" ]]; then
        DOMAIN=$(ls /etc/letsencrypt/live/ 2>/dev/null | grep -v README | head -n1) || true
    fi
    # 4. 最终仍为空则手动输入
    if [[ -z "${DOMAIN:-}" ]]; then
        read -rp "请手动输入域名: " DOMAIN
        [[ -z "$DOMAIN" ]] && { err "域名不能为空。"; return 1; }
    fi
    log "最终使用的域名(sni): $DOMAIN"

    # ---------- 端口与备注（Xray 默认 443 / 1111，可环境变量覆盖） ----------
    PORT="${PORT:-443}"
    REMARK="${REMARK:-1111}"

    # ---------- 公网 IP：优先使用 /root/xray_env.sh 中缓存的 IP，否则探测 ----------
    IP="${IP:-}"
    if [[ -z "$IP" ]]; then
        for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://ipinfo.io/ip" "https://icanhazip.com"; do
            IP=$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]') || true
            [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        done
    fi
    if [[ -z "${IP:-}" ]]; then
        err "无法自动获取公网 IP，请使用 IP=1.2.3.4 环境变量重试。"
        return 1
    fi

    # ---------- URL 编码 path ----------
    local PATH_ENCODED
    PATH_ENCODED="$PATH_RAW"

    # ---------- 拼装链接 ----------
    local VLESS_LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&alpn=h2&insecure=0&allowInsecure=0&type=xhttp&path=${PATH_ENCODED}&mode=packet-up#${REMARK}"

    # ---------- 输出 ----------
    echo "--------------------------------------------"
    echo "来源      : $XRAY_CONFIG"
    echo "UUID      : $UUID"
    echo "IP        : $IP"
    echo "Port      : $PORT"
    echo "Domain    : $DOMAIN"
    echo "Path      : $PATH_RAW"
    echo "Remark    : $REMARK"
    echo "--------------------------------------------"
    echo "当前 VLESS 链接："
    echo "$VLESS_LINK"
    echo "--------------------------------------------"

    # echo "$VLESS_LINK" > /root/vless_link.txt
    # log "链接已保存至 /root/vless_link.txt"
}

# ============================================================
# 主循环
# ============================================================
while true; do
    show_menu
    read -rp "请选择 [0-3]: " CHOICE
    case "$CHOICE" in
        1) do_install ;;
        2) do_uninstall ;;
        3) do_show_link ;;
        0) log "退出。"; exit 0 ;;
        *) warn "无效选项，请重新输入。" ;;
    esac
    echo ""
    read -rp "按回车返回主菜单..." _
done