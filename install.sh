#!/bin/bash

# =====================================================
# Cloudflare DDNS 全平台自适应安装脚本-优化IPv4、IPv6，去重
# 兼容性：Systemd (Ubuntu/Debian/CentOS) & OpenRC (Alpine)
# =====================================================

# --- 1. 环境准备与权限检查 ---
if [[ $EUID -ne 0 ]]; then
   echo "❌ 错误: 必须使用 root 权限运行!"
   exit 1
fi

# --- 2. 配置输入 ---
echo "====================================================="
echo "        Cloudflare DDNS 安装向导"
echo "====================================================="
read -p "1. 请输入 Cloudflare API Token: " CF_TOKEN
read -p "2. 请输入 Zone ID: " ZONE_ID
read -p "3. 请输入 IPv4 域名: " NAME_V4
read -p "4. 请输入 IPv6 域名: " NAME_V6

# --- 3. 生成执行脚本 ---
# 写入执行逻辑到 /usr/local/bin/cf-ddns.sh
cat << 'EOF' > /usr/local/bin/cf-ddns.sh
#!/bin/sh
# 注意：配置变量由安装程序通过 sed 自动填充在上方

update_record() {
    local TYPE=$1; local CURRENT_IP=$2; local RECORD_NAME=$3
    [ -z "$CURRENT_IP" ] || [ -z "$RECORD_NAME" ] && return

    # 查询记录
    API_URL="https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$TYPE&name=$RECORD_NAME"
    RESPONSE=$(curl -s -X GET "$API_URL" -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json")
    RECORD_IDS=$(echo "$RESPONSE" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
    
    # 逻辑：无记录则新增，有记录则更新第一条并清理其余重复项
    if [ -z "$RECORD_IDS" ]; then
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
             -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
             --data "{\"type\":\"$TYPE\",\"name\":\"$RECORD_NAME\",\"content\":\"$CURRENT_IP\",\"ttl\":120,\"proxied\":false}" > /dev/null
    else
        first=true
        for id in $RECORD_IDS; do
            if [ "$first" = true ]; then
                curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$id" \
                     -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
                     --data "{\"type\":\"$TYPE\",\"name\":\"$RECORD_NAME\",\"content\":\"$CURRENT_IP\",\"ttl\":120,\"proxied\":false}" > /dev/null
                first=false
            else
                curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$id" \
                     -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" > /dev/null
            fi
        done
    fi
}

[ -n "$NAME_V4" ] && update_record "A" "$(curl -s --max-time 10 ipv4.icanhazip.com)" "$NAME_V4"
[ -n "$NAME_V6" ] && update_record "AAAA" "$(curl -s --max-time 10 ipv6.icanhazip.com)" "$NAME_V6"
EOF

# 将配置信息插入脚本头部
sed -i "2i CF_TOKEN=\"$CF_TOKEN\"" /usr/local/bin/cf-ddns.sh
sed -i "3i ZONE_ID=\"$ZONE_ID\"" /usr/local/bin/cf-ddns.sh
sed -i "4i NAME_V4=\"$NAME_V4\"" /usr/local/bin/cf-ddns.sh
sed -i "5i NAME_V6=\"$NAME_V6\"" /usr/local/bin/cf-ddns.sh

chmod +x /usr/local/bin/cf-ddns.sh

# --- 4. 配置定时任务 ---
if [ -f /etc/alpine-release ]; then
    (crontab -l 2>/dev/null | grep -v "cf-ddns.sh"; echo "*/5 * * * * /usr/local/bin/cf-ddns.sh") | crontab -
else
    # 清理旧的 systemd 服务
    rm -f /etc/systemd/system/cf-ddns.service /etc/systemd/system/cf-ddns.timer
    
    cat << EOF > /etc/systemd/system/cf-ddns.service
[Unit]
Description=Cloudflare DDNS Update
[Service]
Type=oneshot
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
    systemctl daemon-reload && systemctl enable --now cf-ddns.timer
fi

echo -e "\n🎉 安装完成！脚本已部署，且具备自动清理重复记录的功能。"
