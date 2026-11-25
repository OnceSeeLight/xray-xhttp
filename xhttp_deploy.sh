#!/usr/bin/env bash
set -uo pipefail

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
    echo "     Xray 部署管理脚本（Nginx / Caddy 双模式）"
    echo "============================================"
    echo "  1) 安装并配置 (Nginx + Certbot + Xray)"
    echo "  2) 全部卸载 (清理所有组件与配置)"
    echo "  3) 查看当前 VLESS 链接"
    echo "  4) 【推荐】Caddy 模式安装 Xray（没有 Caddy 会自动装）"
    echo "  5) 卸载 Caddy 模式下的 Xray"
    echo "  0) 退出"
    echo "============================================"
}

# ============================================================
# 安装流程
# ============================================================
do_install() {
    step "开始安装"

    # ---------- 端口冲突预检（避免 Nginx 与 Caddy 抢 80/443） ----------
    if ss -lntp 2>/dev/null | grep -qE ':(80|443)[[:space:]].*caddy'; then
        err "80/443 已被 Caddy 占用，Nginx 方案无法启动。"
        err "请改用菜单 4（Caddy 模式），或先停止 Caddy（会导致现有站点中断）。"
        return 1
    fi

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
# 方案 A：在现有 Caddy 上叠加 Xray（XHTTP）
#   特点：不装 Nginx，Caddy 缺失时自动安装；已有 Caddy 则只追加站点，
#         不改动其现有配置，可在全新服务器上直接运行
# ============================================================
CADDY_FILE="${CADDY_FILE:-/etc/caddy/Caddyfile}"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_ENV="/root/xray_env.sh"
REPO_RAW="https://raw.githubusercontent.com/OnceSeeLight/xray-xhttp/refs/heads/main"

# ---------- 依赖准备：Caddy 不存在则自动安装 ----------
caddy_ensure_installed() {
    if command -v caddy >/dev/null 2>&1; then
        log "Caddy 已安装：$(caddy version 2>/dev/null | head -n1)"
        return 0
    fi
    warn "未检测到 Caddy，开始自动安装（官方 Cloudsmith 源）..."

    apt update >/dev/null 2>&1 || true
    for _pkg in curl gnupg; do
        dpkg -s "$_pkg" >/dev/null 2>&1 || apt install -y "$_pkg" >/dev/null 2>&1 || true
    done
    command -v curl >/dev/null 2>&1 || { err "缺少 curl，无法安装 Caddy。"; return 1; }

    apt install -y debian-keyring debian-archive-keyring apt-transport-https >/dev/null 2>&1 || true

    if ! curl -1sLf -o /tmp/caddy.gpg.key \
        'https://dl.cloudsmith.io/public/caddy/stable/gpg.key'; then
        err "下载 Caddy GPG 公钥失败，请检查网络（或手动安装 Caddy 后重试）。"
        return 1
    fi
    if command -v gpg >/dev/null 2>&1; then
        gpg --batch --yes --dearmor \
            -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
            /tmp/caddy.gpg.key 2>/dev/null || true
    else
        err "缺少 gnupg，无法导入 Caddy 公钥。"
        return 1
    fi
    if [[ ! -s /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
        err "Caddy 软件源公钥写入失败。"
        return 1
    fi

    # 注意：Cloudsmith 官方的 debian.deb.txt 端点已失效(404)，
    # 这里直接写入经过验证可用的源配置（dists/any-version/Release 可访问）
    cat > /etc/apt/sources.list.d/caddy-stable.list <<'CADDYSRC'
# Source: Caddy / stable (Cloudsmith)
deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main
CADDYSRC
    if [[ ! -s /etc/apt/sources.list.d/caddy-stable.list ]]; then
        err "写入 Caddy 软件源失败。"
        return 1
    fi

    apt update || { err "apt update 失败。"; return 1; }
    apt install -y caddy || { err "Caddy 安装失败。"; return 1; }
    command -v caddy >/dev/null 2>&1 || { err "Caddy 安装后仍不可用。"; return 1; }
    log "Caddy 安装完成：$(caddy version 2>/dev/null | head -n1)"
}

# ---------- 端口冲突预检（按实际监听者判断，不依赖进程名） ----------
caddy_port_conflict() {
    local holder
    holder=$(ss -lntp 2>/dev/null | grep -E ':(80|443)[[:space:]]' | grep -v caddy | head -n1)
    if [[ -n "$holder" ]]; then
        warn "80/443 已有非 Caddy 进程监听，Caddy 将无法绑定："
        echo "  $holder"
        warn "请先停止占用端口的服务（如 nginx/apache）后重试。"
        return 1
    fi
    return 0
}

# ---------- 确保有配置文件且服务在跑 ----------
caddy_ensure_ready() {
    if [[ ! -f "$CADDY_FILE" ]]; then
        warn "未找到 $CADDY_FILE，创建空配置"
        mkdir -p "$(dirname "$CADDY_FILE")"
        printf '# Caddyfile\n' > "$CADDY_FILE"
        [[ -s "$CADDY_FILE" ]] || { err "创建 $CADDY_FILE 失败。"; return 1; }
    fi

    systemctl enable caddy >/dev/null 2>&1 || true
    if systemctl is-active --quiet caddy; then
        log "Caddy 运行中，复用其 80/443 作为 TLS 前端"
        return 0
    fi

    warn "Caddy 未运行，尝试启动..."
    if systemctl start caddy; then
        log "Caddy 已启动"
    else
        err "Caddy 启动失败，请查看：journalctl -u caddy -n 30"
        return 1
    fi
}

# ---------- 防火墙放行提示 ----------
caddy_firewall_hint() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        ufw allow 80/tcp  >/dev/null 2>&1 || true
        ufw allow 443/tcp >/dev/null 2>&1 || true
        log "已放行 ufw 80/443"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-service=http  >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-service=https >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        log "已放行 firewalld http/https"
    fi
}

do_install_caddy() {
    step "Caddy 模式：安装 Xray（Nginx 保持不动）"

    step "[1/7] 前置检查（Caddy 缺失则自动安装）"
    caddy_ensure_installed || return 1
    caddy_port_conflict    || return 1
    caddy_ensure_ready     || return 1
    caddy_firewall_hint

    step "[2/7] 检查 / 安装 Xray"
    if [[ -x "$XRAY_BIN" ]]; then
        log "Xray 已安装，跳过"
    else
        if [[ ! -f /tmp/xray-install.sh ]]; then
            curl -fsSL -o /tmp/xray-install.sh \
                https://github.com/XTLS/Xray-install/raw/main/install-release.sh \
                || { err "下载 Xray 安装脚本失败，请检查网络。"; return 1; }
        fi
        bash /tmp/xray-install.sh install || { err "Xray 安装失败。"; return 1; }
        log "Xray 安装完成"
    fi

    step "[3/7] 准备伪装站页面"
    mkdir -p /var/www/html
    if [[ -s /var/www/html/index.html ]]; then
        log "已存在 /var/www/html/index.html，保留"
    elif wget -q -O /var/www/html/index.html "$REPO_RAW/index.html"; then
        log "伪装页 index.html 已下载"
    else
        warn "伪装页下载失败，使用占位页"
        printf '<!doctype html><html><head><meta charset="utf-8"><title>Welcome</title></head><body><h1>It works</h1></body></html>\n' \
            > /var/www/html/index.html
    fi

    step "[4/7] 域名与密钥参数"
    local DOMAIN="${DOMAIN:-}"
    if [[ -z "$DOMAIN" ]]; then
        read -rp "请输入已解析到本机的域名 (例如 rock.example.com): " DOMAIN
    fi
    if [[ -z "$DOMAIN" ]]; then
        err "域名不能为空。"
        return 1
    fi
    local RESOLVED
    RESOLVED=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
    if [[ -z "$RESOLVED" ]]; then
        warn "域名 $DOMAIN 目前无法解析；Caddy 会持续重试签发证书。"
        warn "请确保 DNS A 记录已指向本机公网 IP。"
    else
        log "DNS 解析：$DOMAIN -> $RESOLVED"
    fi

    # 只提取 UUID / 路径复用，绝不能用 source 覆盖用户刚输入的域名
    if [[ -f "$XRAY_ENV" ]]; then
        local _old_uuid _old_rand
        _old_uuid=$(sed -n 's/^export UUID="\(.*\)"$/\1/p' "$XRAY_ENV" | head -n1)
        _old_rand=$(sed -n 's/^export RANDOM_STR="\(.*\)"$/\1/p' "$XRAY_ENV" | head -n1)
        if [[ -z "${UUID:-}" && -n "$_old_uuid" ]]; then
            UUID="$_old_uuid"
            log "复用现有 UUID：$UUID"
        fi
        if [[ -z "${RANDOM_STR:-}" && -n "$_old_rand" ]]; then
            RANDOM_STR="$_old_rand"
            log "复用现有路径：/api/$RANDOM_STR"
        fi
    fi
    if [[ -z "${UUID:-}" ]]; then
        UUID=$("$XRAY_BIN" uuid)
    fi
    if [[ -z "${RANDOM_STR:-}" ]]; then
        RANDOM_STR=$(set +o pipefail; tr -dc 'a-z' < /dev/urandom | head -c 6)
    fi
    if [[ ${#RANDOM_STR} -ne 6 ]]; then
        err "随机路径生成失败，请重试。"
        return 1
    fi
    log "UUID       : $UUID"
    log "XHTTP 路径 : /api/$RANDOM_STR"

    step "[5/7] 写入 Xray 配置并启动"
    mkdir -p "$(dirname "$XRAY_CONFIG")" /var/log/xray
    if ! curl -fsSL -o /tmp/xray_cfg_tpl.json "$REPO_RAW/config.json"; then
        err "下载 Xray 配置模板失败，请检查网络。"
        return 1
    fi
    if ! python3 - "$UUID" "/api/$RANDOM_STR" <<'PY'
import json, sys
uuid, path = sys.argv[1], sys.argv[2]
d = json.load(open('/tmp/xray_cfg_tpl.json'))
ib = d['inbounds'][0]
ib['port'] = 8080
ib['listen'] = '127.0.0.1'
ib['settings']['clients'][0]['id'] = uuid
ib['streamSettings']['xhttpSettings']['path'] = path
d['log'] = {'loglevel': 'warning', 'access': 'none', 'error': '/var/log/xray/error.log'}
with open('/usr/local/etc/xray/config.json', 'w') as f:
    json.dump(d, f, indent=2)
PY
    then
        err "生成 Xray 配置失败。"
        return 1
    fi
    log "配置已写入：$XRAY_CONFIG"

    if ! "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/tmp/xray_test.log 2>&1; then
        err "Xray 配置校验失败："
        cat /tmp/xray_test.log
        return 1
    fi
    log "Xray 配置校验通过"

    chown -R xray:xray /var/log/xray 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable xray >/dev/null 2>&1 || true
    if ! systemctl restart xray; then
        err "Xray 启动失败，请查看：journalctl -u xray -n 30"
        return 1
    fi
    sleep 1
    if ! systemctl is-active --quiet xray; then
        err "Xray 未处于运行状态，请查看：journalctl -u xray -n 30"
        return 1
    fi
    log "Xray 已启动，监听 127.0.0.1:8080"

    cat > "$XRAY_ENV" <<EOF
export UUID="$UUID"
export DOMAIN="$DOMAIN"
export RANDOM_STR="$RANDOM_STR"
export MODE="caddy"
EOF
    chmod 600 "$XRAY_ENV"
    log "变量已保存：$XRAY_ENV"

    step "[6/7] 写入 Caddy 配置（只新增，不改动已有站点）"
    cp -a "$CADDY_FILE" "${CADDY_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    awk -v d="$DOMAIN" '
        $0 ~ "^# ==== Xray XHTTP \\(" { next }
        $0 ~ "^[[:space:]]*" d "[[:space:]]*\\{" { skip=1 }
        skip && /^\}/ { skip=0; next }
        !skip { print }
    ' "$CADDY_FILE" > /tmp/Caddyfile.new || { err "解析 Caddyfile 失败。"; return 1; }
    printf '\n# ==== Xray XHTTP (%s) ====\n' "$DOMAIN" >> /tmp/Caddyfile.new
    cat >> /tmp/Caddyfile.new <<EOF
$DOMAIN {
    root * /var/www/html
    file_server

    @xhttp path /api/$RANDOM_STR*
    reverse_proxy @xhttp 127.0.0.1:8080 {
        flush_interval -1
    }

    log {
        output discard
    }
}
EOF

    if ! caddy validate --config /tmp/Caddyfile.new --adapter caddyfile >/tmp/caddy_val.log 2>&1; then
        err "Caddy 配置校验失败，未做任何改动："
        tail -5 /tmp/caddy_val.log
        return 1
    fi
    log "Caddy 配置校验通过"
    cp /tmp/Caddyfile.new "$CADDY_FILE"

    if systemctl reload caddy; then
        log "Caddy 已平滑重载（现有站点未中断）"
    else
        warn "Caddy 重载失败，可用备份回滚：ls -l ${CADDY_FILE}.bak.*"
    fi

    step "[7/7] 安装完成"
    echo "域名      : $DOMAIN"
    echo "UUID      : $UUID"
    echo "XHTTP 路径: /api/$RANDOM_STR"
    echo "本地监听  : 127.0.0.1:8080"
    echo "变量文件  : $XRAY_ENV"
    echo "--------------------------------------------"
    do_show_link
}

# ============================================================
# 卸载：仅移除 Caddy 模式下的 Xray 及站点块
# ============================================================
do_uninstall_caddy() {
    step "卸载 Caddy 模式下的 Xray"
    read -rp "确认卸载？(输入 yes 继续): " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        warn "已取消。"
        return 0
    fi

    local DOMAIN=""
    if [[ -f "$XRAY_ENV" ]]; then
        # shellcheck disable=SC1090
        source "$XRAY_ENV"
    fi
    [[ -z "${DOMAIN:-}" ]] && read -rp "请输入要移除的域名: " DOMAIN

    step "[1/4] 停止并移除 Xray"
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
    if command -v xray >/dev/null 2>&1 && [[ -f /tmp/xray-install.sh ]]; then
        bash /tmp/xray-install.sh remove --purge || true
    fi
    log "Xray 已移除"

    step "[2/4] 从 Caddyfile 移除站点块"
    if [[ -n "$DOMAIN" && -f "$CADDY_FILE" ]]; then
        cp -a "$CADDY_FILE" "${CADDY_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
        awk -v d="$DOMAIN" '
            $0 ~ "^# ==== Xray XHTTP \\(" { next }
            $0 ~ "^[[:space:]]*" d "[[:space:]]*\\{" { skip=1 }
            skip && /^\}/ { skip=0; next }
            !skip { print }
        ' "$CADDY_FILE" > /tmp/Caddyfile.new || { err "解析 Caddyfile 失败。"; return 1; }
        if ! command -v caddy >/dev/null 2>&1; then
            warn "未安装 Caddy，直接覆盖配置文件"
            cp /tmp/Caddyfile.new "$CADDY_FILE"
        elif caddy validate --config /tmp/Caddyfile.new --adapter caddyfile >/dev/null 2>&1; then
            cp /tmp/Caddyfile.new "$CADDY_FILE"
            systemctl reload caddy && log "Caddy 已重载，站点块已移除"
        else
            err "移除后配置校验失败，已保留原 Caddyfile，请手动检查。"
        fi
    else
        warn "未获取到域名，跳过 Caddyfile 清理。"
    fi

    step "[3/4] 清理文件"
    rm -f "$XRAY_ENV" /root/vless_link.txt
    log "变量文件已清理"

    step "[4/4] 完成"
    echo "如需彻底清理，可另行删除 /var/www/html/index.html"
}

# ============================================================
# 主循环
# ============================================================
while true; do
    show_menu
    read -rp "请选择 [0-5]: " CHOICE
    case "$CHOICE" in
        1) do_install || warn "安装未完成，已返回主菜单。" ;;
        2) do_uninstall ;;
        3) do_show_link ;;
        4) do_install_caddy || warn "Caddy 模式安装未完成，已返回主菜单。" ;;
        5) do_uninstall_caddy ;;
        0) log "退出。"; exit 0 ;;
        *) warn "无效选项，请重新输入。" ;;
    esac
    echo ""
    read -rp "按回车返回主菜单..." _
done