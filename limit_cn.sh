#!/bin/bash

# ====================================================
# Debian 12 IPTABLES + IPSET China-Only Firewall
# ====================================================

# 配置：SSH 端口 (如果你修改过 SSH 端口，请在这里更改)
SSH_PORT=22

# 配置：是否允许全球 SSH？ (建议 true，防止误锁)
# true = 允许所有 IP 连 SSH
# false = 只允许中国 IP 连 SSH (风险较高，请确保你有 VNC)
ALLOW_ALL_SSH=true

# 数据源
CN_IP_URL="http://www.ipdeny.com/ipblocks/data/countries/cn.zone"
IPSET_NAME="cn_ip"
TMP_IP_FILE="/tmp/cn.zone"

# 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
   echo "错误: 必须以 root 权限运行此脚本。"
   exit 1
fi

echo ">> [1/6] 清理环境..."
# 卸载 UFW 防止冲突
if command -v ufw > /dev/null; then
    echo ">> 检测到 UFW，正在禁用并卸载以防止冲突..."
    ufw disable > /dev/null 2>&1
    apt-get remove -y ufw > /dev/null 2>&1
fi

echo ">> [2/6] 安装 iptables-persistent 和 ipset..."
# 使用 noninteractive 防止安装过程弹出对话框
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y ipset iptables iptables-persistent netfilter-persistent curl -qq

echo ">> [3/6] 配置 IPSET 集合..."
# 创建名为 cn_ip 的集合，hash:net 专门用于存储网段
ipset create $IPSET_NAME hash:net -exist
# 清空集合（如果是重新运行脚本）
ipset flush $IPSET_NAME

echo ">> 正在下载中国大陆 IP 列表..."
curl -s -o "$TMP_IP_FILE" "$CN_IP_URL"

if [ ! -f "$TMP_IP_FILE" ]; then
    echo "错误: 下载 IP 列表失败。"
    exit 1
fi

echo ">> 正在将 IP 导入 IPSET (极速模式)..."
# 生成 ipset restore 格式的文件，速度比循环 add 快几百倍
sed -i "s/^/add $IPSET_NAME /" "$TMP_IP_FILE"
# 导入 (-! 表示忽略已存在的报错)
ipset restore -! < "$TMP_IP_FILE"

IP_COUNT=$(ipset list $IPSET_NAME | wc -l)
echo ">> 已导入约 $((IP_COUNT - 6)) 个 IP 段。"

echo ">> [4/6] 配置 IPTABLES 规则..."

# 1. 清空旧规则
iptables -F
iptables -X
iptables -Z

# 2. 允许本地回环 (Localhost)
iptables -A INPUT -i lo -j ACCEPT

# 3. 允许已建立的连接 (这一步至关重要，否则服务器无法回包)
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# 4. SSH 策略
if [ "$ALLOW_ALL_SSH" = true ]; then
    echo ">> 添加规则: 允许所有 IP 连接 SSH ($SSH_PORT)..."
    iptables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT
else
    echo ">> 警告: SSH 仅限中国 IP 访问，请确保你现在的连接不会断开！"
fi

# 5. 核心规则: 允许来自 ipset 集合的流量
echo ">> 添加规则: 允许中国 IP ($IPSET_NAME) 访问所有端口..."
iptables -A INPUT -m set --match-set $IPSET_NAME src -j ACCEPT

# 6. 默认策略: 拒绝其他所有进入的流量
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

echo ">> [5/6] 保存规则..."
# 保存 iptables 规则
netfilter-persistent save
# 保存 ipset 规则 (确保重启后集合还在)
# Debian 的 netfilter-persistent 插件通常会自动处理，但为了保险手动存一份
ipset save > /etc/iptables/ipsets

echo ">> [6/6] 完成！"
echo "========================================================"
echo "当前状态: 防火墙已激活。"
echo "规则逻辑: ESTABLISHED -> SSH -> CN_IP -> DROP"
echo "查看 iptables 状态: iptables -L -n --line-numbers"
echo "查看 ipset 状态:    ipset list $IPSET_NAME | head"
echo "========================================================"

# 清理
rm -f "$TMP_IP_FILE"