#!/bin/bash

# =====================================================
# Cloudflare DDNS 全平台自适应安装脚本 (带 IP 缓存优化版)
# 兼容性：Systemd (Ubuntu/Debian/CentOS) & OpenRC (Alpine)
# =====================================================

# --- 1. 环境准备与权限检查 ---
if [[ $EUID -ne 0 ]]; then
   echo "❌ 错误: 必须使用 root 权限运行!"
   exit 1
fi

# --- 2. 配置输入 ---
echo "====================================================="
echo "        Cloudflare DDNS 安装向导 (带 IP 缓存)"
echo "====================================================="
read -p "1. 请输入 Cloudflare API Token: " CF_TOKEN
read -p "2. 请输入 Zone ID: " ZONE_ID
read -p "3. 请输入 IPv4 域名 (不填请直接回车): " NAME_V4
read -p "4. 请输入 IPv6 域名 (不填请直接回车): " NAME_V6

# --- 3. 生成执行脚本 ---
cat << 'EOF' > /usr/local/bin/cf-ddns.sh
#!/bin/bash

CF_TOKEN="REPLACE_CF_TOKEN"
ZONE_ID="REPLACE_ZONE_ID"
NAME_V4="REPLACE_NAME_V4"
NAME_V6="REPLACE_NAME_V6"

CACHE_DIR="/var/lib/cf-ddns"
mkdir -p "$CACHE_DIR"

update_record() {
    local TYPE="$1"
    local CURRENT_IP="$2"
    local RECORD_NAME="$3"

    if [ -z "$CURRENT_IP" ] || [ -z "$RECORD_NAME" ]; then
        return 0
    fi

    # 查询记录
    API_URL="https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$TYPE&name=$RECORD_NAME"
    RESPONSE=$(curl -s -m 15 -X GET "$API_URL" -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json")
    RECORD_IDS=$(echo "$RESPONSE" | grep -o '"id":"[^"]*' | cut -d'"' -f4)

    # 逻辑：无记录则新增，有记录则更新第一条并清理其余重复项
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

# --- 处理 IPv4 ---
if [ -n "$NAME_V4" ]; then
    IPV4_VAL=$(curl -s -m 10 ipv4.icanhazip.com || curl -s -m 10 api.ipify.org || echo "")
    if [ -n "$IPV4_VAL" ]; then
        V4_CACHE_FILE="$CACHE_DIR/ipv4.cache"
        OLD_IPV4=""
        [ -f "$V4_CACHE_FILE" ] && OLD_IPV4=$(cat "$V4_CACHE_FILE")

        if [ "$IPV4_VAL" != "$OLD_IPV4" ]; then
            echo "[$(date)] IPv4 变动: $OLD_IPV4 -> $IPV4_VAL，正在更新 Cloudflare..."
            update_record "A" "$IPV4_VAL" "$NAME_V4"
            echo "$IPV4_VAL" > "$V4_CACHE_FILE"
        else
            # IP 未变，跳过 API 提交
            true
        fi
    fi
fi

# --- 处理 IPv6 ---
if [ -n "$NAME_V6" ]; then
    IPV6_VAL=$(curl -s -m 10 ipv6.icanhazip.com || curl -s -m 10 api64.ipify.org || echo "")
    if [ -n "$IPV6_VAL" ]; then
        V6_CACHE_FILE="$CACHE_DIR/ipv6.cache"
        OLD_IPV6=""
        [ -f "$V6_CACHE_FILE" ] && OLD_IPV6=$(cat "$V6_CACHE_FILE")

        if [ "$IPV6_VAL" != "$OLD_IPV6" ]; then
            echo "[$(date)] IPv6 变动: $OLD_IPV6 -> $IPV6_VAL，正在更新 Cloudflare..."
            update_record "AAAA" "$IPV6_VAL" "$NAME_V6"
            echo "$IPV6_VAL" > "$V6_CACHE_FILE"
        else
            # IP 未变，跳过 API 提交
            true
        fi
    fi
fi

exit 0
EOF

# 替换脚本中的变量占位符
sed -i "s|REPLACE_CF_TOKEN|$CF_TOKEN|g" /usr/local/bin/cf-ddns.sh
sed -i "s|REPLACE_ZONE_ID|$ZONE_ID|g" /usr/local/bin/cf-ddns.sh
sed -i "s|REPLACE_NAME_V4|$NAME_V4|g" /usr/local/bin/cf-ddns.sh
sed -i "s|REPLACE_NAME_V6|$NAME_V6|g" /usr/local/bin/cf-ddns.sh

chmod +x /usr/local/bin/cf-ddns.sh

# --- 4. 配置定时任务 ---
if [ -f /etc/alpine-release ]; then
    (crontab -l 2>/dev/null | grep -v "cf-ddns.sh"; echo "*/5 * * * * /usr/local/bin/cf-ddns.sh >/dev/null 2>&1") | crontab -
else
    # 清理旧的 systemd 服务
    systemctl stop cf-ddns.timer 2>/dev/null
    systemctl disable cf-ddns.timer 2>/dev/null
    rm -f /etc/systemd/system/cf-ddns.service /etc/systemd/system/cf-ddns.timer

    cat << EOF > /etc/systemd/system/cf-ddns.service
[Unit]
Description=Cloudflare DDNS Update with Cache
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/usr/local/bin/cf-ddns.sh
EOF

    cat << EOF > /etc/systemd/system/cf-ddns.timer
[Unit]
Description=Run CF DDNS every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now cf-ddns.timer
fi

echo -e "\n🎉 安装完成！正在测试初次运行..."
if /usr/local/bin/cf-ddns.sh; then
    echo "✅ 初始化测试成功！IP 缓存已存入 /var/lib/cf-ddns/ 目录。"
else
    echo "⚠️ 初次运行遇到问题，请检查 Token 和 Zone ID 是否正确。"
fi

