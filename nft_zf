[2026/5/7 13:35] Kimi: #!/bin/bash

# ========================================
# nftables 端口转发配置脚本 最终版
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

# 第三步：固定 DNS
echo ">>> 固定 DNS..."
chattr -i /etc/resolv.conf 2>/dev/null
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
chattr +i /etc/resolv.conf

# 第四步：创建转发表和链（分开检测，防止中途中断导致缺失）
echo ">>> 创建转发表和链..."
nft list table ip port_forward > /dev/null 2>&1 || nft add table ip port_forward
nft list chain ip port_forward prerouting > /dev/null 2>&1 || nft add chain ip port_forward prerouting '{ type nat hook prerouting priority 0; policy accept; }'
nft list chain ip port_forward postrouting > /dev/null 2>&1 || nft add chain ip port_forward postrouting '{ type nat hook postrouting priority 100; policy accept; }'
nft list ruleset | grep -q "masquerade" || nft add rule ip port_forward postrouting masquerade

# 第五步：安装 nft-add 快捷命令
echo ">>> 安装 nft-add 快捷命令..."
cat > /usr/local/bin/nft-add << 'EOF'
#!/bin/bash

if [[ "${EUID}" -ne 0 ]]; then
    echo "请以 root 权限运行此脚本"
    exit 1
fi

while true; do
    echo ""
    echo "========================================"
    read -rp "请输入本机转发端口（直接回车退出）: " FORWARD_PORT
    if [[ -z "$FORWARD_PORT" ]]; then
        break
    fi

    read -rp "请输入落地机 IP: " TARGET_IP
    read -rp "请输入落地机端口: " TARGET_PORT

    # 验证端口是否为数字
    if ! [[ "$FORWARD_PORT" =~ ^[0-9]+$ ]] || ! [[ "$TARGET_PORT" =~ ^[0-9]+$ ]]; then
        echo "错误：端口必须为数字，请重新输入"
        continue
    fi

    # 验证端口范围
    if (( FORWARD_PORT < 1  FORWARD_PORT > 65535  TARGET_PORT < 1 || TARGET_PORT > 65535 )); then
        echo "错误：端口范围必须在 1-65535 之间，请重新输入"
        continue
    fi

    # 验证 IP 不为空
    if [[ -z "$TARGET_IP" ]]; then
        echo "错误：落地机 IP 不能为空，请重新输入"
        continue
    fi

    # 添加规则
    nft add rule ip port_forward prerouting tcp dport "$FORWARD_PORT" dnat to "$TARGET_IP:$TARGET_PORT"
    nft add rule ip port_forward prerouting udp dport "$FORWARD_PORT" dnat to "$TARGET_IP:$TARGET_PORT"

    echo ">>> 规则已添加: $FORWARD_PORT → $TARGET_IP:$TARGET_PORT"

    read -rp "是否继续添加规则？(y/n): " CONTINUE
    if [[ "$CONTINUE" != "y" ]]; then
        break
    fi
done

# 自动保存
nft list ruleset > /etc/nftables.conf
echo ">>> 规则已保存"
echo ""
echo "当前所有规则："
nft list ruleset
EOF
chmod +x /usr/local/bin/nft-add

# 第六步：询问输入转发规则
echo ""
echo "========================================"
echo "基础配置完成，现在开始添加转发规则"
echo "========================================"

while true; do
    echo ""
    read -rp "请输入本机转发端口（直接回车跳过）: " FORWARD_PORT
    if [[ -z "$FORWARD_PORT" ]]; then
        break
    fi

    read -rp "请输入落地机 IP: " TARGET_IP
    read -rp "请输入落地机端口: " TARGET_PORT

    # 验证端口是否为数字
    if ! [[ "$FORWARD_PORT" =~ ^[0-9]+$ ]] || ! [[ "$TARGET_PORT" =~ ^[0-9]+$ ]]; then
        echo "错误：端口必须为数字，请重新输入"
        continue
    fi

    # 验证端口范围
    if (( FORWARD_PORT < 1  FORWARD_PORT > 65535  TARGET_PORT < 1 || TARGET_PORT > 65535 )); then
        echo "错误：端口范围必须在 1-65535 之间，请重新输入"
        continue
    fi

    # 验证 IP 不为空
    if [[ -z "$TARGET_IP" ]]; then
        echo "错误：落地机 IP 不能为空，请重新输入"
        continue
    fi

    nft add rule ip port_forward prerouting tcp dport "$FORWARD_PORT" dnat to "$TARGET_IP:$TARGET_PORT"
    nft add rule ip port_forward prerouting udp dport "$FORWARD_PORT" dnat to "$TARGET_IP:$TARGET_PORT"

    echo ">>> 规则已添加: $FORWARD_PORT → $TARGET_IP:$TARGET_PORT"

    read -rp "是否继续添加规则？(y/n): " CONTINUE
    if [[ "$CONTINUE" != "y" ]]; then
        break
    fi
done

# 第七步：保存规则
echo ">>> 保存规则..."
nft list ruleset > /etc/nftables.conf
systemctl enable nftables

echo ""
echo "========================================"
echo "所有配置完成！当前规则如下："
echo "========================================"
nft list ruleset
echo ""
echo "以后新增转发规则只需执行: nft-add"
[2026/5/7 13:35] Kimi: echo "========================================"
