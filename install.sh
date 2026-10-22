#!/bin/bash

# =====================================================
# Cloudflare DDNS 生产级一键管理脚本 (终极稳定版)
# =====================================================

CONFIG_FILE="/etc/cf-ddns.conf"
SCRIPT_PATH="/usr/local/bin/cf-ddns.sh"
SERVICE_PATH="/etc/systemd/system/cf-ddns.service"
TIMER_PATH="/etc/systemd/system/cf-ddns.timer"

# 1. 权限检查
if [[ $EUID -ne 0 ]]; then
   echo "❌ 错误: 必须使用 root 权限运行此脚本！"
   exit 1
fi

# 加载现有配置
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# 2. 核心 DDNS 执行脚本生成函数
write_ddns_script() {
    cat << 'EOF' > "$SCRIPT_PATH"
#!/bin/bash
CONFIG_FILE="/etc/cf-ddns.conf"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" || exit 1

CACHE_DIR="/var/lib/cf-ddns"
mkdir -p "$CACHE_DIR"

update_record() {
    local TYPE="$1"
    local CURRENT_IP="$2"
    local RECORD_NAME="$3"
    [ -z "$CURRENT_IP" ] || [ -z "$RECORD_NAME" ] && return 0

    API_URL="https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$TYPE&name=$RECORD_NAME"
    RESPONSE=$(curl -s -m 15 -X GET "$API_URL" -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json")
    RECORD_IDS=$(echo "$RESPONSE" | grep -o '"id":"[^"]*' | cut -d'"' -f4)

    if [ -z "$RECORD_IDS" ]; then
        curl -s -m 15 -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
             -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
             --data "{\"type\":\"$TYPE\",\"name\":\"$RECORD_NAME\",\"content\":\"$CURRENT_IP\",\"ttl\":120,\"proxied\":false}" > /dev/null
    else
        first=true
        for id in $RECORD_IDS; do
            if [ "$first" = true ]; then
                curl -s -m 15 -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$id" \
                     -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
                     --data "{\"type\":\"$TYPE\",\"name\":\"$RECORD_NAME\",\"content\":\"$CURRENT_IP\",\"ttl\":120,\"proxied\":false}" > /dev/null
                first=false
            else
                curl -s -m 15 -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$id" \
                     -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" > /dev/null
            fi
        done
    fi
}

# 处理 IPv4
if [ -n "$NAME_V4" ]; then
    IPV4_VAL=$(curl -s -m 10 ipv4.icanhazip.com || curl -s -m 10 api.ipify.org || echo "")
    if [ -n "$IPV4_VAL" ]; then
        V4_CACHE_FILE="$CACHE_DIR/ipv4.cache"
        OLD_IPV4=""
        [ -f "$V4_CACHE_FILE" ] && OLD_IPV4=$(cat "$V4_CACHE_FILE")
        if [ "$IPV4_VAL" != "$OLD_IPV4" ]; then
            echo "[$(date)] IPv4 变动: $OLD_IPV4 -> $IPV4_VAL，正在更新..."
            update_record "A" "$IPV4_VAL" "$NAME_V4"
            echo "$IPV4_VAL" > "$V4_CACHE_FILE"
        fi
    fi
fi

# 处理 IPv6
if [ -n "$NAME_V6" ]; then
    IPV6_VAL=$(curl -s -m 10 ipv6.icanhazip.com || curl -s -m 10 api64.ipify.org || echo "")
    if [ -n "$IPV6_VAL" ]; then
        V6_CACHE_FILE="$CACHE_DIR/ipv6.cache"
        OLD_IPV6=""
        [ -f "$V6_CACHE_FILE" ] && OLD_IPV6=$(cat "$V6_CACHE_FILE")
        if [ "$IPV6_VAL" != "$OLD_IPV6" ]; then
            echo "[$(date)] IPv6 变动: $OLD_IPV6 -> $IPV6_VAL，正在更新..."
            update_record "AAAA" "$IPV6_VAL" "$NAME_V6"
            echo "$IPV6_VAL" > "$V6_CACHE_FILE"
        fi
    fi
fi
exit 0
EOF
    chmod +x "$SCRIPT_PATH"
}

# 3. 菜单界面
show_menu() {
    clear
    echo "====================================================="
    echo "        Cloudflare DDNS 管理与安装面板"
    echo "====================================================="
    echo " 1. 安装 / 更新 DDNS 配置并启动服务"
    echo " 2. 手动执行一次 DDNS 更新测试"
    echo " 3. 查看最近运行日志"
    echo " 4. 卸载 DDNS 及清理相关文件"
    echo " 0. 退出脚本"
    echo "-----------------------------------------------------"
    read -p "请选择操作 [0-4]: " CHOICE
}

# 4. 安装逻辑
install_ddns() {
    echo "====================================================="
    echo "          Cloudflare DDNS 配置向导"
    echo "====================================================="
    read -p "1. 请输入 Cloudflare API Token [${CF_TOKEN:-}]: " input_token
    CF_TOKEN="${input_token:-$CF_TOKEN}"

    read -p "2. 请输入 Zone ID [${ZONE_ID:-}]: " input_zone
    ZONE_ID="${input_zone:-$ZONE_ID}"

    read -p "3. 请输入 IPv4 域名 (不填请直接回车) [${NAME_V4:-}]: " input_v4
    NAME_V4="${input_v4:-$NAME_V4}"

    read -p "4. 请输入 IPv6 域名 (不填请直接回车) [${NAME_V6:-}]: " input_v6
    NAME_V6="${input_v6:-$NAME_V6}"

    if [ -z "$CF_TOKEN" ] || [ -z "$ZONE_ID" ]; then
        echo "❌ 错误: API Token 和 Zone ID 不能为空！"
        read -p "按回车键返回主菜单..."
        return
    fi

    cat << EOF > "$CONFIG_FILE"
CF_TOKEN="$CF_TOKEN"
ZONE_ID="$ZONE_ID"
NAME_V4="$NAME_V4"
NAME_V6="$NAME_V6"
EOF
    chmod 600 "$CONFIG_FILE"

    write_ddns_script

    if [ -f /etc/alpine-release ]; then
        (crontab -l 2>/dev/null | grep -v "cf-ddns.sh"; echo "*/5 * * * * /usr/local/bin/cf-ddns.sh >/dev/null 2>&1") | crontab -
    else
        systemctl stop cf-ddns.timer 2>/dev/null
        systemctl disable cf-ddns.timer 2>/dev/null
        rm -f "$SERVICE_PATH" "$TIMER_PATH"

        cat << EOF > "$SERVICE_PATH"
[Unit]
Description=Cloudflare DDNS Update Service with Cache
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=$SCRIPT_PATH
EOF

        cat << EOF > "$TIMER_PATH"
[Unit]
Description=Run Cloudflare DDNS every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

        systemctl daemon-reload
        systemctl enable --now cf-ddns.timer
    fi

    echo -e "\n🎉 安装/更新完成！正在执行一次初始化测试..."
    "$SCRIPT_PATH"
    read -p "按回车键返回主菜单..."
}

# 5. 手动运行
run_manual() {
    if [ ! -f "$SCRIPT_PATH" ]; then
        echo "❌ 核心脚本不存在，请先安装配置！"
    else
        echo "🚀 正在手动执行 DDNS 更新..."
        "$SCRIPT_PATH"
    fi
    read -p "按回车键返回主菜单..."
}

# 6. 查看日志
view_logs() {
    echo "====================================================="
    echo "        最近的 DDNS 运行日志"
    echo "====================================================="
    if [ -f /etc/alpine-release ]; then
        echo "Alpine 系统请通过 crontab 或系统日志查看。"
    else
        journalctl -u cf-ddns.service -n 50 --no-pager
    fi
    echo "-----------------------------------------------------"
    read -p "按回车键返回主菜单..."
}

# 7. 卸载
uninstall_ddns() {
    read -p "⚠️ 确认要完全卸载 Cloudflare DDNS 吗？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -f "$CONFIG_FILE" "$SCRIPT_PATH"
        rm -rf "/var/lib/cf-ddns"
        if [ -f /etc/alpine-release ]; then
            crontab -l 2>/dev/null | grep -v "cf-ddns.sh" | crontab -
        else
            systemctl disable --now cf-ddns.timer 2>/dev/null
            rm -f "$SERVICE_PATH" "$TIMER_PATH"
            systemctl daemon-reload
        fi
        echo "✅ 已完全卸载。"
    else
        echo "已取消卸载。"
    fi
    read -p "按回车键返回主菜单..."
}

# 主循环
while true; do
    show_menu
    case "$CHOICE" in
        1) install_ddns ;;
        2) run_manual ;;
        3) view_logs ;;
        4) uninstall_ddns ;;
        0) echo "再见！"; exit 0 ;;
        *) echo "无效的选择，请重新输入。"; sleep 1 ;;
    esac
done

