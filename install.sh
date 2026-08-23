#!/bin/bash

# =====================================================
# Cloudflare DDNS 全平台自适应安装脚本 (终极稳定版)
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
read -p "3. 请输入 IPv4 域名 (不填请直接回车): " NAME_V4
read -p "4. 请输入 IPv6 域名 (不填请直接回车): " NAME_V6

# --- 3. 生成执行脚本 ---
cat << EOF > /usr/local/bin/cf-ddns.sh
#!/bin/bash

CF_TOKEN="$CF_TOKEN"
ZONE_ID="$ZONE_ID"
NAME_V4="$NAME_V4"
NAME_V6="$NAME_V6"

update_record() {
    local TYPE="\$1"
    local CURRENT_IP="\$2"
    local RECORD_NAME="\$3"

    # 如果没有获取到有效 IP 或没有配置域名，直接退出该函数的执行
    if [ -z "\$CURRENT_IP" ] || [ -z "\$RECORD_NAME" ]; then
        return 0
    fi

    # 查询记录
    API_URL="https://api.cloudflare.com/client/v4/zones/\$ZONE_ID/dns_records?type=\$TYPE&name=\$RECORD_NAME"
    RESPONSE=\$(curl -s -m 15 -X GET "\$API_URL" -H "Authorization: Bearer \$CF_TOKEN" -H "Content-Type: application/json")
    RECORD_IDS=\$(echo "\$RESPONSE" | grep -o '"id":"[^"]*' | cut -d'"' -f4)

    # 逻辑：无记录则新增，有记录则更新第一条并清理其余重复项
    if [ -z "\$RECORD_IDS" ]; then
        curl -s -m 15 -X POST "https://api.cloudflare.com/client/v4/zones/\$ZONE_ID/dns_records" \
             -H "Authorization: Bearer \$CF_TOKEN" -H "Content-Type: application/json" \
             --data "{\"type\":\"\$TYPE\",\"name\":\"\$RECORD_NAME\",\"content\":\"\$CURRENT_IP\",\"ttl\":120,\"proxied\":false}" > /dev/null
    else
        first=true
        for id in \$RECORD_IDS; do
            if [ "\$first" = true ]; then
                curl -s -m 15 -X PUT "https://api.cloudflare.com/client/v4/zones/\$ZONE_ID/dns_records/\$id" \
                     -H "Authorization: Bearer \$CF_TOKEN" -H "Content-Type: application/json" \
                     --data "{\"type\":\"\$TYPE\",\"name\":\"\$RECORD_NAME\",\"content\":\"\$CURRENT_IP\",\"ttl\":120,\"proxied\":false}" > /dev/null
                first=false
            else
                curl -s -m 15 -X DELETE "https://api.cloudflare.com/client/v4/zones/\$ZONE_ID/dns_records/\$id" \
                     -H "Authorization: Bearer \$CF_TOKEN" -H "Content-Type: application/json" > /dev/null
            fi
        done
    fi
}

# 获取公网 IP (加 -s 静音，-m 10 10秒超时)
IPV4_VAL=""
IPV6_VAL=""

if [ -n "\$NAME_V4" ]; then
    IPV4_VAL=\$(curl -s -m 10 ipv4.icanhazip.com || curl -s -m 10 api.ipify.org || echo "")
    update_record "A" "\$IPV4_VAL" "\$NAME_V4"
fi

if [ -n "\$NAME_V6" ]; then
    IPV6_VAL=\$(curl -s -m 10 ipv6.icanhazip.com || curl -s -m 10 api64.ipify.org || echo "")
    update_record "AAAA" "\$IPV6_VAL" "\$NAME_V6"
fi

exit 0
EOF

chmod +x /usr/local/bin/cf-ddns.sh

# --- 4. 配置定时任务 ---
if [ -f /etc/alpine-release ]; then
    (crontab -l 2>/dev/null | grep -v "cf-ddns.sh"; echo "*/5 * * * * /usr/local/bin/cf-ddns.sh") | crontab -
else
    # 清理旧的 systemd 服务
    systemctl stop cf-ddns.timer 2>/dev/null
    systemctl disable cf-ddns.timer 2>/dev/null
    rm -f /etc/systemd/system/cf-ddns.service /etc/systemd/system/cf-ddns.timer

    cat << EOF > /etc/systemd/system/cf-ddns.service
[Unit]
Description=Cloudflare DDNS Update
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

echo -e "\n🎉 安装完成！正在测试启动服务..."
if systemctl start cf-ddns.service; then
    echo "✅ 服务启动成功！可以通过 'systemctl status cf-ddns.timer' 查看定时任务启动状态。"
else
    echo "⚠️ 服务手动测试启动失败，请检查上方配置项。`"
fi
