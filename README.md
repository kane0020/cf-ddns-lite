# Cloudflare DDNS 一键脚本

这是一个极致轻量的 Cloudflare DDNS 自动更新脚本，支持自动创建解析记录。

## 🌟 特性
- **全平台自适应**：支持 Ubuntu / Debian / CentOS (Systemd) 以及 Alpine Linux (OpenRC)。
- **零依赖常驻**：依赖系统的定时任务调度，执行完即退出，绝不占用系统内存。
- **高频率检查**：默认每 5 分钟检查一次公网 IP 变动，变动时自动同步。

## 📖 准备工作

在使用一键脚本前，请确保获取并保存好以下三项核心参数：

> 1. **CF_TOKEN**：请输入 Cloudflare API Token
> 2. **ZONE_ID**：请输入 区域 ID
> 3. **RECORD_NAME**：请输入 完整域名（例如 `ddns.example.com`）

### 🔐 详细参数获取步骤：
1. **获取区域 ID (Zone ID)**：
   - 登录 Cloudflare 控制台，进入你需要使用的域名。
   - 查看右下侧的 **API 区域**，复制 **区域 ID (Zone ID)** 到本地文本中备用。
2. **创建 API 令牌 (CF_TOKEN)**：
   - 点击右上角头像 $\rightarrow$ 选择 **配置文件** $\rightarrow$ 打开左侧 **API 令牌**。
   - 点击右上角 **创建令牌** $\rightarrow$ 在 “API 令牌模板” 中找到 **编辑区域 DNS**，点击 **使用模板**。
   - 进入后设置权限：【权限】保持默认；【区域资源】前两项默认，第三项选择**你要使用的域名**；【客户端 IP 地址筛选】与【TTL】保持默认。
   - 点击 **继续以显示摘要** $\rightarrow$ 点击 **创建令牌**。
   - ⚠️ *注意：此令牌只显示一次，请立刻复制并妥善保存到本地。*

---

## 🚀 一键安装

使用 root 权限或 sudo 执行以下命令即可开始交互式安装：

```bash
curl -fsSL https://raw.githubusercontent.com/kane0020/cf-ddns-lite/main/install.sh | sudo bash
```

---

## 📖 使用说明

### 🔹 如果你使用的是普通 Linux (Systemd)
* **查看运行日志**：
  ```bash
  journalctl -u cf-ddns.service
  ```
* **查看下一次运行时间**：
  ```bash
  systemctl list-timers | grep cf-ddns
  ```
* **手动立刻触发更新**：
  ```bash
  sudo systemctl start cf-ddns.service
  ```

### 🔹 如果你使用的是 Alpine Linux (OpenRC)
* **查看定时任务**：
  ```bash
  crontab -l
  ```
* **手动运行测试**：
  ```bash
  /usr/local/bin/cf-ddns.sh
  ```

---

## 🗑️ 如何卸载

如果你不再需要此脚本，可以按照以下步骤进行手动清理：

### 🛑 Systemd 系统（Ubuntu / Debian / CentOS）
```bash
sudo systemctl stop cf-ddns.timer
sudo systemctl disable cf-ddns.timer
sudo rm -f /etc/systemd/system/cf-ddns.*
sudo rm -f /usr/local/bin/cf-ddns.sh
sudo systemctl daemon-reload
```

### 🛑 OpenRC 系统（Alpine）
```bash
# 进入 crontab 编辑模式删除对应的定时任务行
crontab -e

# 然后删除脚本文件
rm -f /usr/local/bin/cf-ddns.sh
```
