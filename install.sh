#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 配置文件路径
TARGET_DIR="/var/lib/vastai_kaalia"
TARGET_SCRIPT="$TARGET_DIR/send_mach_info.py"
VPS_CONFIG="$TARGET_DIR/.speedtest_vps"
SERVICE_NAME="vastai-speedtest"
TIMER_NAME="vastai-speedtest"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Vast.ai 测速脚本安装工具${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# 检查是否以root运行
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}错误: 请使用 root 权限运行此脚本${NC}"
    echo "使用: sudo bash $0"
    exit 1
fi

# 检查目标目录是否存在
if [ ! -d "$TARGET_DIR" ]; then
    echo -e "${RED}错误: 目录 $TARGET_DIR 不存在${NC}"
    echo "请确保这是一台 Vast.ai 机器"
    exit 1
fi

# 检查是否已安装(通过检查配置文件)
ALREADY_INSTALLED=false
if [ -f "$VPS_CONFIG" ]; then
    ALREADY_INSTALLED=true
    CURRENT_VPS=$(cat "$VPS_CONFIG")
    echo -e "${YELLOW}检测到已安装的配置${NC}"
    echo -e "当前测速VPS: ${GREEN}$CURRENT_VPS${NC}"
    echo ""
fi

# 获取VPS IP地址
if [ "$ALREADY_INSTALLED" = true ]; then
    echo -e "${YELLOW}是否要更新测速VPS地址? (y/n)${NC}"
    read -p "> " UPDATE_VPS
    if [ "$UPDATE_VPS" = "y" ] || [ "$UPDATE_VPS" = "Y" ]; then
        echo -e "${GREEN}请输入新的测速VPS IP地址:${NC}"
        read -p "> " VPS_IP
        if [ -z "$VPS_IP" ]; then
            echo -e "${RED}错误: VPS地址不能为空${NC}"
            exit 1
        fi
        echo "$VPS_IP" > "$VPS_CONFIG"
        echo -e "${GREEN}✓ VPS地址已更新为: $VPS_IP${NC}"
    else
        VPS_IP="$CURRENT_VPS"
        echo -e "${GREEN}保持使用当前VPS: $VPS_IP${NC}"
    fi
else
    echo -e "${GREEN}请输入测速VPS的IP地址:${NC}"
    read -p "> " VPS_IP
    if [ -z "$VPS_IP" ]; then
        echo -e "${RED}错误: VPS地址不能为空${NC}"
        exit 1
    fi
    echo "$VPS_IP" > "$VPS_CONFIG"
    echo -e "${GREEN}✓ VPS地址已保存: $VPS_IP${NC}"
fi

echo ""

# 下载并覆盖脚本文件
echo -e "${GREEN}正在更新 send_mach_info.py ...${NC}"

# 尝试从当前目录获取脚本文件
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT="$SCRIPT_DIR/send_mach_info.py"

# GitHub仓库地址（请替换为实际地址）
GITHUB_RAW_URL="https://raw.githubusercontent.com/YOUR_USERNAME/vast-speedtest-vps/main/send_mach_info.py"

# 备份原文件
if [ -f "$TARGET_SCRIPT" ]; then
    cp "$TARGET_SCRIPT" "$TARGET_SCRIPT.backup.$(date +%Y%m%d_%H%M%S)"
    echo -e "${YELLOW}原文件已备份${NC}"
fi

# 优先使用本地文件，如果不存在则从GitHub下载
if [ -f "$SOURCE_SCRIPT" ]; then
    echo -e "${YELLOW}使用本地脚本文件${NC}"
    cp "$SOURCE_SCRIPT" "$TARGET_SCRIPT"
    chmod +x "$TARGET_SCRIPT"
    echo -e "${GREEN}✓ 脚本文件已更新${NC}"
else
    echo -e "${YELLOW}本地文件不存在，从GitHub下载...${NC}"
    
    # 尝试使用curl下载
    if command -v curl &> /dev/null; then
        if curl -fsSL "$GITHUB_RAW_URL" -o "$TARGET_SCRIPT"; then
            chmod +x "$TARGET_SCRIPT"
            echo -e "${GREEN}✓ 脚本文件已从GitHub下载${NC}"
        else
            echo -e "${RED}错误: 从GitHub下载失败${NC}"
            exit 1
        fi
    # 尝试使用wget下载
    elif command -v wget &> /dev/null; then
        if wget -qO "$TARGET_SCRIPT" "$GITHUB_RAW_URL"; then
            chmod +x "$TARGET_SCRIPT"
            echo -e "${GREEN}✓ 脚本文件已从GitHub下载${NC}"
        else
            echo -e "${RED}错误: 从GitHub下载失败${NC}"
            exit 1
        fi
    else
        echo -e "${RED}错误: 系统中未找到 curl 或 wget${NC}"
        echo "请安装 curl 或 wget 后重试"
        exit 1
    fi
fi

echo ""

# 创建 systemd service 文件
echo -e "${GREEN}正在配置自动运行服务...${NC}"

cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Vast.ai Speedtest Service
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$TARGET_DIR
ExecStart=/usr/bin/python3 $TARGET_SCRIPT --speedtest
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vastai-speedtest

[Install]
WantedBy=multi-user.target
EOF

echo -e "${GREEN}✓ Service 文件已创建${NC}"

# 创建 systemd timer 文件 (每天随机时间运行一次)
cat > "/etc/systemd/system/${TIMER_NAME}.timer" << EOF
[Unit]
Description=Vast.ai Speedtest Timer (Daily Random)
Requires=${SERVICE_NAME}.service

[Timer]
OnCalendar=daily
RandomizedDelaySec=86400
Persistent=true

[Install]
WantedBy=timers.target
EOF

echo -e "${GREEN}✓ Timer 文件已创建 (每天随机时间运行)${NC}"

# 重载 systemd 并启用服务
systemctl daemon-reload
systemctl enable "${TIMER_NAME}.timer"
systemctl start "${TIMER_NAME}.timer"

echo -e "${GREEN}✓ 自动运行服务已启用${NC}"
echo ""

# 立即运行一次测速
echo -e "${GREEN}正在执行首次测速...${NC}"
echo -e "${YELLOW}这可能需要几分钟时间,请耐心等待...${NC}"
echo ""

cd "$TARGET_DIR"
python3 "$TARGET_SCRIPT" --speedtest

if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}✓ 测速完成!${NC}"
else
    echo ""
    echo -e "${YELLOW}⚠ 测速执行遇到问题,请检查日志${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}安装完成!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${GREEN}配置信息:${NC}"
echo -e "  测速VPS: ${YELLOW}$VPS_IP${NC}"
echo -e "  脚本位置: ${YELLOW}$TARGET_SCRIPT${NC}"
echo -e "  配置文件: ${YELLOW}$VPS_CONFIG${NC}"
echo ""
echo -e "${GREEN}使用说明:${NC}"
echo -e "  手动测速: ${YELLOW}cd $TARGET_DIR && python3 send_mach_info.py --speedtest${NC}"
echo -e "  查看服务状态: ${YELLOW}systemctl status ${SERVICE_NAME}.timer${NC}"
echo -e "  查看运行日志: ${YELLOW}journalctl -u ${SERVICE_NAME} -f${NC}"
echo -e "  停止自动运行: ${YELLOW}systemctl stop ${TIMER_NAME}.timer${NC}"
echo -e "  启动自动运行: ${YELLOW}systemctl start ${TIMER_NAME}.timer${NC}"
echo -e "  更新VPS地址: ${YELLOW}重新运行此脚本${NC}"
echo ""
echo -e "${GREEN}下次自动运行时间:${NC}"
systemctl list-timers "${TIMER_NAME}.timer" --no-pager
echo ""
