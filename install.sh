#!/bin/bash

# =====================================================
# Cloudflare DDNS 全平台自适应安装脚本
# 兼容性：Systemd (Ubuntu/Debian/CentOS) & OpenRC (Alpine)
# =====================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 1. 权限检查
[[ $EUID -ne 0 ]] && echo -e "${RED}❌ 错误: 必须使用 root 权限运行!${PLAIN}" && exit 1

# 2. 环境自动检测
IS_ALPINE=false
if [ -f /etc/alpine-release ]; then
    IS_ALPINE=true
    INIT_SYS="OpenRC"
elif command -v systemctl >/dev/null 2>&1; then
    IS_ALPINE=false
    INIT_SYS="Systemd"
else
    echo -e "${RED}❌ 错误: 无法识别的系统初始化类型，仅支持 Systemd 或 Alpine OpenRC。${PLAIN}"
    exit 1
fi

echo -e "${GREEN}检测到系统环境: $INIT_SYS${PLAIN}"

# 3. 依赖安装
echo -e "${YELLOW}正在检查并安装依赖...${PLAIN}"
if [ "$IS_ALPINE" = true ]; then
    apk add --no-cache curl grep cut sed
else
    # 针对普通 Linux 的依赖安装
    deps=("curl" "grep" "cut" "sed")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            if command -v apt >/dev/null 2>&1; then apt update && apt install -y "$dep";
            elif command -v yum >/dev/null 2>&1; then yum install -y "$dep";
            fi
        fi
    done
fi

clear
echo "====================================================="
echo "    Cloudflare DDNS 自适应安装向导 ($INIT_SYS)"
echo "====================================================="
echo ""

read -p "1. 请输入 Cloudflare API Token: " CF_TOKEN
read -p "2. 请输入 Zone ID: " ZONE_ID
read -p "3. 请输入完整域名: " RECORD_NAME

CF_TOKEN=$(echo "$CF_TOKEN" | xargs)
ZONE_ID=$(echo "$ZONE_ID" | xargs)
RECORD_NAME=$(echo "$RECORD_NAME" | xargs)

if [[ -z "$CF_TOKEN" || -z "$ZONE_ID" || -z "$RECORD_NAME" ]]; then
    echo -e "${RED}❌ 错误: 参数不能为空！${PLAIN}"
    exit 1
fi

# 4. 生成执行脚本
mkdir -p /usr/local/bin
cat << INNER_EOF > /usr/local/bin/cf-ddns.sh
#!/bin/sh
# 配置信息
CF_TOKEN="$CF_TOKEN"
ZONE_ID="$ZONE_ID"
RECORD_NAME="$RECORD_NAME"

# 获取 IP
CURRENT_IP=\$(curl -s --max-time 10 icanhazip.com)
[ -z "\$CURRENT_IP" ] && exit 1

API_URL="https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$RECORD_NAME"

RECORD_INFO=\$(curl -s -X GET "\$API_URL" \\
     -H "Authorization: Bearer \$CF_TOKEN" \\
     -H "Content-Type: application/json")

RECORD_ID=\$(echo "\$RECORD_INFO" | grep -o '"id":"[^"]*' | head -n1 | cut -d'"' -f4)
CF_IP=\$(echo "\$RECORD_INFO" | grep -o '"content":"[^"]*' | head -n1 | cut -d'"' -f4)

if [ -z "\$RECORD_ID" ]; then
    # 创建记录
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \\
         -H "Authorization: Bearer \$CF_TOKEN" \\
         -H "Content-Type: application/json" \\
         --data "{\"type\":\"A\",\"name\":\"\$RECORD_NAME\",\"content\":\"\$CURRENT_IP\",\"ttl\":120,\"proxied\":false}" > /dev/null
elif [ "\$CURRENT_IP" != "\$CF_IP" ]; then
    # 更新记录
    curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \\
         -H "Authorization: Bearer \$CF_TOKEN" \\
         -H "Content-Type: application/json" \\
         --data "{\"type\":\"A\",\"name\":\"\$RECORD_NAME\",\"content\":\"\$CURRENT_IP\",\"ttl\":120,\"proxied\":false}" > /dev/null
fi
INNER_EOF

chmod +x /usr/local/bin/cf-ddns.sh

# 5. 根据系统类型配置定时任务
if [ "$IS_ALPINE" = true ]; then
    echo -e "${YELLOW}正在配置 Alpine OpenRC/Cron...${PLAIN}"
    rc-update add crond default >/dev/null 2>&1
    rc-service crond start >/dev/null 2>&1
    (crontab -l 2>/dev/null | grep -v "/usr/local/bin/cf-ddns.sh"; echo "*/5 * * * * /usr/local/bin/cf-ddns.sh") | crontab -
else
    echo -e "${YELLOW}正在配置 Systemd Timer...${PLAIN}"
    cat << EOF > /etc/systemd/system/cf-ddns.service
[Unit]
Description=Cloudflare DDNS Update Service
After=network-online.target
Wants=network-online.target

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
RandomizedDelaySec=5s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now cf-ddns.timer
fi

echo ""
echo -e "====================================================="
echo -e "🎉 ${GREEN}安装成功！已适配 $INIT_SYS 环境${PLAIN}"
echo -e "-----------------------------------------------------"
echo -e "🔹 域名: ${YELLOW}$RECORD_NAME${PLAIN}"
echo -e "🔹 频率: 每 5 分钟检查一次"
echo -e "🔹 脚本: /usr/local/bin/cf-ddns.sh"
echo -e "====================================================="
