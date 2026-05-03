#!/bin/bash

# ========================================
# nftables 端口转发配置脚本
# ========================================

# 检查是否以 root 运行
if [[ "${EUID}" -ne 0 ]]; then
    echo "请以 root 权限运行此脚本"
    exit 1
fi

# 第一步：安装 nftables
echo ">>> 安装 nftables..."
apt install -y nftables

# 第二步：开启内核转发
echo ">>> 开启内核转发..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forward.conf
sysctl -p /etc/sysctl.d/99-forward.conf

# 第三步：固定 DNS（防止 masquerade 导致 DNS 失效）
echo ">>> 固定 DNS..."
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
chattr +i /etc/resolv.conf

# 第四步：创建转发表和链
echo ">>> 创建转发表和链..."
nft add table ip port_forward
nft add chain ip port_forward prerouting '{ type nat hook prerouting priority 0; policy accept; }'
nft add chain ip port_forward postrouting '{ type nat hook postrouting priority 100; policy accept; }'

# 第五步：添加 masquerade
echo ">>> 添加 masquerade..."
nft add rule ip port_forward postrouting masquerade

# 第六步：保存规则
echo ">>> 保存规则..."
nft list ruleset > /etc/nftables.conf
systemctl enable nftables

echo ""
echo "========================================" 
echo "基础配置完成！"
echo "现在可以手动添加转发规则："
echo ""
echo "添加规则命令："
echo "  nft add rule ip port_forward prerouting tcp dport 本机端口 dnat to 目标IP:目标端口"
echo "  nft add rule ip port_forward prerouting udp dport 本机端口 dnat to 目标IP:目标端口"
echo ""
echo "添加完规则后记得保存："
echo "  nft list ruleset > /etc/nftables.conf"
echo "========================================"
