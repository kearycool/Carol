Content is user-generated and unverified.
#!/usr/bin/env bash
# nftables 端口转发管理脚本
# 支持：添加/删除/列出转发规则，TCP+UDP，IPv4+IPv6，幂等安全

set -euo pipefail

# ──────────────────────────────────────────────
# 常量
# ──────────────────────────────────────────────
NFT_PERSIST="/etc/nftables.d/port-forward.nft"
SYSCTL_CONF="/etc/sysctl.d/99-nft-forward.conf"
INSTALL_PATH="/usr/local/bin/nft-forward"

# ──────────────────────────────────────────────
# 工具函数
# ──────────────────────────────────────────────
info()  { echo -e "\e[32m[INFO]\e[0m  $*"; }
warn()  { echo -e "\e[33m[WARN]\e[0m  $*"; }
error() { echo -e "\e[31m[ERR]\e[0m   $*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || error "请以 root 权限运行此脚本。"
}

install_nftables() {
  info "未找到 nft，尝试自动安装..."
  if   command -v apt-get &>/dev/null; then apt-get update -qq && apt-get install -y nftables
  elif command -v dnf     &>/dev/null; then dnf install -y nftables
  elif command -v yum     &>/dev/null; then yum install -y nftables
  elif command -v zypper  &>/dev/null; then zypper install -y nftables
  elif command -v pacman  &>/dev/null; then pacman -Sy --noconfirm nftables
  elif command -v apk     &>/dev/null; then apk add --no-cache nftables
  else error "无法识别的包管理器，请手动安装 nftables。"
  fi
  command -v nft &>/dev/null || error "nftables 安装失败，请手动排查。"
  info "nftables 安装成功。"
}

enable_ipforward() {
  mkdir -p "$(dirname "$SYSCTL_CONF")"
  cat > "$SYSCTL_CONF" <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
  sysctl --system >/dev/null
}

# 确保 nftables 里存在我们自己的表和链，不影响其他表
ensure_tables() {
  # IPv4
  nft list table ip port_forward &>/dev/null || nft add table ip port_forward
  nft list chain ip port_forward prerouting &>/dev/null || \
    nft add chain ip port_forward prerouting \
      '{ type nat hook prerouting priority dstnat; policy accept; }'
  nft list chain ip port_forward postrouting &>/dev/null || \
    nft add chain ip port_forward postrouting \
      '{ type nat hook postrouting priority srcnat; policy accept; }'

  # IPv6
  nft list table ip6 port_forward &>/dev/null || nft add table ip6 port_forward
  nft list chain ip6 port_forward prerouting &>/dev/null || \
    nft add chain ip6 port_forward prerouting \
      '{ type nat hook prerouting priority dstnat; policy accept; }'
  nft list chain ip6 port_forward postrouting &>/dev/null || \
    nft add chain ip6 port_forward postrouting \
      '{ type nat hook postrouting priority srcnat; policy accept; }'
}

# 判断目标 IP 是 IPv4 还是 IPv6
ip_family() {
  local ip="$1"
  if [[ "$ip" =~ : ]]; then echo "ip6"
  else echo "ip"
  fi
}

# 保存当前规则到持久化文件
save_rules() {
  mkdir -p "$(dirname "$NFT_PERSIST")"
  {
    echo "#!/usr/sbin/nft -f"
    echo "# 由 nft-forward 自动生成，请勿手动修改"
    echo ""
    nft list table ip  port_forward 2>/dev/null || true
    nft list table ip6 port_forward 2>/dev/null || true
  } > "$NFT_PERSIST"

  # 让系统 nftables 服务加载时包含此文件
  local main_conf="/etc/nftables.conf"
  if [[ -f "$main_conf" ]] && ! grep -q "port-forward.nft" "$main_conf"; then
    echo "include \"$NFT_PERSIST\"" >> "$main_conf"
    info "已将持久化文件加入 $main_conf"
  fi

  if command -v systemctl &>/dev/null; then
    systemctl enable nftables &>/dev/null || true
  fi
}

validate_port() {
  local port="$1" name="$2"
  [[ "$port" =~ ^[0-9]+$ ]] || error "$name 必须为数字。"
  # 用 if 而非 (( )) || error，避免 set -e 下 (( )) 为假时直接退出
  if ! (( port >= 1 && port <= 65535 )); then
    error "$name 必须在 1-65535 范围内。"
  fi
}

validate_ip() {
  local ip="$1"
  [[ -n "$ip" ]] || error "目标 IP 不能为空。"
  if ! python3 -c "import ipaddress; ipaddress.ip_address('$ip')" &>/dev/null; then
    if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$ip" =~ : ]]; then
      error "IP 格式不合法：$ip"
    fi
  fi
}

# ──────────────────────────────────────────────
# 子命令：添加规则
# ──────────────────────────────────────────────
cmd_add() {
  local fport tip tport family dest
  read -rp "本机转发端口 (FORWARD_PORT): " fport
  read -rp "目标 IP      (TARGET_IP)   : " tip
  read -rp "目标端口     (TARGET_PORT) : " tport

  validate_port "$fport" "FORWARD_PORT"
  validate_port "$tport" "TARGET_PORT"
  validate_ip   "$tip"

  family=$(ip_family "$tip")

  ensure_tables

  # 检查是否已存在相同规则（幂等）
  if nft list chain "${family}" port_forward prerouting 2>/dev/null \
      | grep -q "dport ${fport} dnat to"; then
    warn "端口 ${fport} 的转发规则已存在，跳过添加。"
    warn "如需修改请先删除旧规则：nft-del"
    return
  fi

  # IPv6 目标地址需要加方括号
  if [[ "$family" == "ip6" ]]; then
    dest="[${tip}]:${tport}"
  else
    dest="${tip}:${tport}"
  fi

  # 添加 DNAT 规则
  nft add rule "${family}" port_forward prerouting \
    tcp dport "${fport}" dnat to "${dest}"
  nft add rule "${family}" port_forward prerouting \
    udp dport "${fport}" dnat to "${dest}"

  # MASQUERADE 只对发往目标 IP 的流量生效，避免影响本机其他节点
  if [[ "$family" == "ip6" ]]; then
    nft add rule ip6 port_forward postrouting \
      ip6 daddr "${tip}" masquerade
  else
    nft add rule ip port_forward postrouting \
      ip daddr "${tip}" masquerade
  fi

  save_rules

  info "规则添加成功："
  info "  ${fport} → ${tip}:${tport}  (TCP+UDP, ${family})"
}

# ──────────────────────────────────────────────
# 子命令：列出规则
# ──────────────────────────────────────────────
cmd_list() {
  echo ""
  echo "══════════════ 当前端口转发规则 ══════════════"
  local family found=0 output

  for family in ip ip6; do
    if nft list table "${family}" port_forward &>/dev/null; then
      output=$(nft list chain "${family}" port_forward prerouting 2>/dev/null \
        | grep -E "dport.*dnat" || true)
      if [[ -n "$output" ]]; then
        echo ""
        echo "── ${family} ──"
        nft -a list chain "${family}" port_forward prerouting 2>/dev/null \
          | grep -E "dport.*dnat" || true
        found=1
      fi
    fi
  done

  if [[ $found -eq 0 ]]; then
    echo "  （暂无转发规则）"
  fi
  echo ""
  echo "══════════════════════════════════════════════"
  echo ""
  echo "提示：句柄号(handle)可用于 nft-del 精确删除规则"
}

# ──────────────────────────────────────────────
# 子命令：删除规则
# ──────────────────────────────────────────────
cmd_del() {
  local mode
  cmd_list

  echo "删除方式："
  echo "  1) 按本机转发端口删除"
  echo "  2) 按句柄号精确删除"
  read -rp "请选择 [1/2]: " mode

  case "$mode" in
    1)
      local fport family handles h remaining ph deleted=0
      read -rp "请输入要删除的本机转发端口: " fport
      validate_port "$fport" "FORWARD_PORT"

      for family in ip ip6; do
        nft list table "${family}" port_forward &>/dev/null || continue

        handles=$(nft -a list chain "${family}" port_forward prerouting 2>/dev/null \
          | awk "/dport ${fport} dnat/{print \$NF}" || true)

        for h in $handles; do
          nft delete rule "${family}" port_forward prerouting handle "$h"
          info "已删除 ${family} prerouting handle $h"
          deleted=1
        done

        # 若该 family 下已无 dnat 规则，则一并清理 masquerade
        remaining=$(nft list chain "${family}" port_forward prerouting 2>/dev/null \
          | grep -c "dnat" || true)
        if (( remaining == 0 )); then
          ph=$(nft -a list chain "${family}" port_forward postrouting 2>/dev/null \
            | awk "/masquerade/{print \$NF}" | head -1 || true)
          if [[ -n "$ph" ]]; then
            nft delete rule "${family}" port_forward postrouting handle "$ph"
            info "已删除 ${family} postrouting masquerade handle $ph"
          fi
        fi
      done

      if (( deleted == 0 )); then
        warn "未找到端口 ${fport} 的转发规则。"
      fi
      ;;
    2)
      local family chain handle
      read -rp "请输入 family (ip/ip6): " family
      read -rp "请输入链名 (prerouting/postrouting): " chain
      read -rp "请输入句柄号: " handle
      nft delete rule "${family}" port_forward "${chain}" handle "${handle}"
      info "已删除 ${family} port_forward ${chain} handle ${handle}"
      ;;
    *)
      error "无效选择，请输入 1 或 2。"
      ;;
  esac

  save_rules
}

# ──────────────────────────────────────────────
# 子命令：清空所有转发规则（只删自己的表）
# ──────────────────────────────────────────────
cmd_flush() {
  local confirm family
  read -rp "确认清空所有端口转发规则？[y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { info "已取消。"; return; }

  for family in ip ip6; do
    if nft list table "${family}" port_forward &>/dev/null; then
      nft delete table "${family}" port_forward
      info "已删除 ${family} port_forward 表"
    fi
  done

  if [[ -f "$NFT_PERSIST" ]]; then
    echo "#!/usr/sbin/nft -f" > "$NFT_PERSIST"
    info "已清空持久化文件 $NFT_PERSIST"
  fi
}

# ──────────────────────────────────────────────
# 子命令：安装快捷命令到系统
# ──────────────────────────────────────────────
cmd_install() {
  local self action bin_dir="/usr/local/bin"
  self=$(realpath "$0")

  # 若脚本不在 INSTALL_PATH，先复制过去，确保软链接指向固定路径
  if [[ "$self" != "$INSTALL_PATH" ]]; then
    info "将脚本复制到 $INSTALL_PATH ..."
    cp "$self" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
  fi

  for action in add list del flush; do
    ln -sf "$INSTALL_PATH" "${bin_dir}/nft-${action}"
    info "已创建快捷命令：nft-${action}"
  done

  info "安装完成！现在可以直接使用以下命令："
  info "  nft-add   - 添加转发规则"
  info "  nft-list  - 查看当前规则"
  info "  nft-del   - 删除指定规则"
  info "  nft-flush - 清空所有转发规则"
}

# ──────────────────────────────────────────────
# 主入口
# ──────────────────────────────────────────────
require_root
command -v nft &>/dev/null || install_nftables
enable_ipforward

# 自动安装快捷命令（首次运行时）
if [[ ! -L "/usr/local/bin/nft-add" ]]; then
  info "首次运行，自动安装快捷命令..."
  cmd_install
fi

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   nftables 端口转发管理              ║"
echo "╠══════════════════════════════════════╣"
echo "║  add     - 添加转发规则              ║"
echo "║  list    - 查看当前规则              ║"
echo "║  del     - 删除指定规则              ║"
echo "║  flush   - 清空所有转发规则          ║"
echo "║  install - 重新安装 nft-* 快捷命令   ║"
echo "╚══════════════════════════════════════╝"
echo ""

# 从文件名推断操作（软链接场景）
# nft-add → add，nft-list → list
# nft-forward 本身 → 显示菜单让用户选择
SELF=$(basename "$0")
if [[ "$SELF" =~ ^nft-(.+)$ && "${BASH_REMATCH[1]}" != "forward" ]]; then
  ACTION="${BASH_REMATCH[1]}"
else
  ACTION="${1:-}"
  if [[ -z "$ACTION" ]]; then
    read -rp "请选择操作 [add/list/del/flush/install]: " ACTION
  fi
fi

case "$ACTION" in
  add)     cmd_add     ;;
  list)    cmd_list    ;;
  del)     cmd_del     ;;
  flush)   cmd_flush   ;;
  install) cmd_install ;;
  *)       error "未知操作：$ACTION，可选：add / list / del / flush / install" ;;
esac
