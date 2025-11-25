#!/bin/bash

# Vast.ai 远程测速服务一键安装脚本
# 使用方法: curl -sSL https://raw.githubusercontent.com/your-repo/setup_vastai_speedtest.sh | bash

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Vast.ai 远程测速服务安装脚本 v1.0          ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}"
echo ""

# 检查是否以root运行
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}请使用 root 权限运行此脚本${NC}"
    echo "使用: sudo bash $0"
    exit 1
fi

# 配置文件路径
SPEEDTEST_VPS_FILE="/var/lib/vastai_kaalia/.speedtest_vps"
GITHUB_URL_FILE="/var/lib/vastai_kaalia/.github_url"
SCRIPT_PATH="/var/lib/vastai_kaalia/send_mach_info.py"
SERVICE_FILE="/etc/systemd/system/vastai-speedtest.service"
TIMER_FILE="/etc/systemd/system/vastai-speedtest.timer"

# 默认GitHub URL
DEFAULT_GITHUB_URL="https://raw.githubusercontent.com/chenshaoquan/axisaispeed/main/send_mach_info.py"

# 检查是否已安装
if [ -f "$SPEEDTEST_VPS_FILE" ]; then
    CURRENT_VPS=$(cat "$SPEEDTEST_VPS_FILE")
    echo -e "${YELLOW}⚠ 检测到已配置的测速VPS: ${GREEN}$CURRENT_VPS${NC}"
    echo ""
    read -p "是否要更改测速VPS地址? (y/n): " CHANGE_VPS
    
    if [ "$CHANGE_VPS" != "y" ] && [ "$CHANGE_VPS" != "Y" ]; then
        echo -e "${GREEN}✓ 保持当前配置: $CURRENT_VPS${NC}"
        SPEEDTEST_VPS="$CURRENT_VPS"
    else
        read -p "请输入新的测速VPS IP地址: " SPEEDTEST_VPS
        if [ -z "$SPEEDTEST_VPS" ]; then
            echo -e "${RED}✗ 错误: IP地址不能为空${NC}"
            exit 1
        fi
        echo "$SPEEDTEST_VPS" > "$SPEEDTEST_VPS_FILE"
        echo -e "${GREEN}✓ 已更新测速VPS地址为: $SPEEDTEST_VPS${NC}"
    fi
else
    # 首次安装
    echo -e "${YELLOW}请输入测速VPS的IP地址${NC}"
    echo -e "${BLUE}提示: 确保已执行 ssh-copy-id root@<VPS_IP> 配置免密登录${NC}"
    echo ""
    read -p "测速VPS IP地址: " SPEEDTEST_VPS
    
    if [ -z "$SPEEDTEST_VPS" ]; then
        echo -e "${RED}✗ 错误: IP地址不能为空${NC}"
        exit 1
    fi
    
    # 保存VPS地址
    mkdir -p /var/lib/vastai_kaalia/data
    echo "$SPEEDTEST_VPS" > "$SPEEDTEST_VPS_FILE"
    echo -e "${GREEN}✓ 已保存测速VPS地址: $SPEEDTEST_VPS${NC}"
fi

echo ""
echo -e "${YELLOW}配置GitHub仓库地址${NC}"
echo -e "${BLUE}脚本将从GitHub自动更新，请输入send_mach_info.py的raw URL${NC}"
echo -e "${BLUE}默认: https://raw.githubusercontent.com/chenshaoquan/axisaispeed/main/send_mach_info.py${NC}"
echo ""

# 检查是否已有GitHub URL配置
if [ -f "$GITHUB_URL_FILE" ]; then
    CURRENT_GITHUB_URL=$(cat "$GITHUB_URL_FILE")
    echo -e "${YELLOW}当前配置: ${GREEN}$CURRENT_GITHUB_URL${NC}"
    read -p "使用当前配置? (y/n): " USE_CURRENT
    if [ "$USE_CURRENT" = "y" ] || [ "$USE_CURRENT" = "Y" ]; then
        GITHUB_URL="$CURRENT_GITHUB_URL"
    else
        read -p "请输入新的GitHub URL: " GITHUB_URL
        if [ -z "$GITHUB_URL" ]; then
            echo -e "${YELLOW}使用默认URL${NC}"
            GITHUB_URL="$DEFAULT_GITHUB_URL"
        fi
    fi
else
    read -p "GitHub URL (留空使用默认): " GITHUB_URL
    if [ -z "$GITHUB_URL" ]; then
        GITHUB_URL="$DEFAULT_GITHUB_URL"
    fi
fi

echo "$GITHUB_URL" > "$GITHUB_URL_FILE"
echo -e "${GREEN}✓ 已保存GitHub URL: $GITHUB_URL${NC}"

echo ""
echo -e "${YELLOW}[1/6] 测试SSH连接到 $SPEEDTEST_VPS ...${NC}"

# 测试SSH连接
if timeout 10 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@"$SPEEDTEST_VPS" 'echo "SSH连接成功"' 2>/dev/null; then
    echo -e "${GREEN}✓ SSH连接测试成功${NC}"
else
    echo -e "${RED}✗ SSH连接失败${NC}"
    echo -e "${YELLOW}请先配置SSH免密登录:${NC}"
    echo -e "  ${BLUE}ssh-copy-id root@$SPEEDTEST_VPS${NC}"
    echo ""
    read -p "是否继续安装? (y/n): " CONTINUE
    if [ "$CONTINUE" != "y" ] && [ "$CONTINUE" != "Y" ]; then
        exit 1
    fi
fi

echo ""
echo -e "${YELLOW}[2/6] 检查VPS上的speedtest工具...${NC}"

# 检查VPS上是否安装了speedtest
if timeout 10 ssh -o StrictHostKeyChecking=no root@"$SPEEDTEST_VPS" 'which speedtest' &>/dev/null; then
    echo -e "${GREEN}✓ VPS上已安装speedtest${NC}"
else
    echo -e "${YELLOW}⚠ VPS上未检测到speedtest，请在VPS上安装:${NC}"
    echo -e "  ${BLUE}curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash${NC}"
    echo -e "  ${BLUE}apt install -y speedtest${NC}"
    echo ""
fi

echo ""
echo -e "${YELLOW}[3/6] 创建主脚本 send_mach_info.py ...${NC}"

# 创建Python脚本
cat > "$SCRIPT_PATH" << 'PYTHON_SCRIPT_EOF'
#!/usr/bin/python3
import json
import subprocess
import requests
import random
import os
import time
from argparse import ArgumentParser
from datetime import datetime

def epsilon_greedyish_speedtest():
    """
    通过SSH连接到远端VPS执行测速
    VPS地址从配置文件读取: /var/lib/vastai_kaalia/.speedtest_vps
    """
    # 从配置文件读取VPS地址
    try:
        with open('/var/lib/vastai_kaalia/.speedtest_vps', 'r') as f:
            REMOTE_VPS = f.read().strip()
        if not REMOTE_VPS:
            raise ValueError("VPS地址为空")
        print(f"使用测速VPS: {REMOTE_VPS}")
    except Exception as e:
        print(f"错误: 无法读取测速VPS配置: {e}")
        print("请先运行安装脚本配置测速VPS地址")
        return None
    
    def epsilon(greedy):
        # 在远端VPS上获取服务器列表
        print(f"Getting speedtest server list from remote VPS {REMOTE_VPS}")
        try:
            output = subprocess.check_output(
                f"ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@{REMOTE_VPS} 'speedtest -L --accept-license --accept-gdpr --format=json'",
                shell=True,
                timeout=30
            ).decode('utf-8')
        except subprocess.TimeoutExpired:
            print("获取服务器列表超时")
            return None
        except Exception as e:
            print(f"获取服务器列表失败: {e}")
            return None
        
        mirrors = [server["id"] for server in json.loads(output)["servers"]]
        mirror = mirrors[random.randint(0, len(mirrors)-1)]
        print(f"Running speedtest on random server id {mirror} via remote VPS")
        
        # 在远端VPS上执行测速
        try:
            output = subprocess.check_output(
                f"ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@{REMOTE_VPS} 'speedtest -s {mirror} --accept-license --accept-gdpr --format=json'",
                shell=True,
                timeout=60
            ).decode('utf-8')
        except subprocess.TimeoutExpired:
            print("测速超时")
            return None
        except Exception as e:
            print(f"测速失败: {e}")
            return None
        
        joutput = json.loads(output)
        score = joutput["download"]["bandwidth"] + joutput["upload"]["bandwidth"]
        
        if int(score) > int(greedy):
            subprocess.run(["mkdir", "-p", "/var/lib/vastai_kaalia/data"], check=False)
            with open("/var/lib/vastai_kaalia/data/speedtest_mirrors", "w") as f:
                f.write(f"{mirror},{score}")
        return output
    
    def greedy(id):
        print(f"Running speedtest on known best server id {id} via remote VPS {REMOTE_VPS}")
        try:
            output = subprocess.check_output(
                f"ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@{REMOTE_VPS} 'speedtest -s {id} --accept-license --accept-gdpr --format=json'",
                shell=True,
                timeout=60
            ).decode('utf-8')
        except subprocess.TimeoutExpired:
            print("测速超时")
            return None
        except Exception as e:
            print(f"测速失败: {e}")
            return None
        
        joutput = json.loads(output)
        score = joutput["download"]["bandwidth"] + joutput["upload"]["bandwidth"]
        
        subprocess.run(["mkdir", "-p", "/var/lib/vastai_kaalia/data"], check=False)
        with open("/var/lib/vastai_kaalia/data/speedtest_mirrors", "w") as f:
            f.write(f"{id},{score}")
        return output
    
    try:
        with open("/var/lib/vastai_kaalia/data/speedtest_mirrors") as f:
            id, score = f.read().split(',')[0:2]
        if random.randint(0, 2):
            return greedy(id)
        else:
            return epsilon(score)
    except:
        return epsilon(0)

if __name__ == '__main__':
    parser = ArgumentParser()
    parser.add_argument("--speedtest", action='store_true', help='Run speedtest')
    parser.add_argument("--server", action='store', default="https://console.vast.ai")
    args = parser.parse_args()
    
    print(f"=== Vast.ai Speedtest Reporter ===")
    print(f"Time: {datetime.now()}")
    print("")
    
    if args.speedtest:
        try:
            print("Starting speedtest...")
            output = epsilon_greedyish_speedtest()
            
            if output:
                print("")
                print("Speedtest completed successfully!")
                jomsg = json.loads(output)
                _MiB = 2 ** 20
                
                try:
                    bwu_cur = 8 * jomsg["upload"]["bandwidth"] / _MiB
                    bwd_cur = 8 * jomsg["download"]["bandwidth"] / _MiB
                except:
                    bwu_cur = 8 * jomsg["upload"] / _MiB
                    bwd_cur = 8 * jomsg["download"] / _MiB
                
                print(f"Download: {bwd_cur:.2f} Mbps")
                print(f"Upload: {bwu_cur:.2f} Mbps")
                print("")
                
                # 这里可以添加上报到Vast.ai服务器的代码
                # 需要machine_id等配置
                
            else:
                print("Speedtest failed!")
                
        except Exception as e:
            print(f"Error during speedtest: {e}")
    else:
        print("Use --speedtest flag to run speedtest")
        print("Example: python3 send_mach_info.py --speedtest")
PYTHON_SCRIPT_EOF

chmod +x "$SCRIPT_PATH"
echo -e "${GREEN}✓ 主脚本已创建${NC}"

echo ""
echo -e "${YELLOW}[4/6] 创建更新脚本...${NC}"

# 创建更新并执行的脚本
UPDATE_SCRIPT="/var/lib/vastai_kaalia/update_and_run.sh"
cat > "$UPDATE_SCRIPT" << 'UPDATE_SCRIPT_EOF'
#!/bin/bash

GITHUB_URL_FILE="/var/lib/vastai_kaalia/.github_url"
SCRIPT_PATH="/var/lib/vastai_kaalia/send_mach_info.py"
BACKUP_PATH="/var/lib/vastai_kaalia/send_mach_info.py.backup"

echo "=== Vast.ai Speedtest Auto Update & Run ==="
echo "Time: $(date)"
echo ""

# 从配置文件读取GitHub URL
if [ -f "$GITHUB_URL_FILE" ]; then
    GITHUB_RAW_URL=$(cat "$GITHUB_URL_FILE")
    echo "GitHub URL: $GITHUB_RAW_URL"
else
    echo "✗ GitHub URL not configured!"
    echo "Please run the installation script again."
    exit 1
fi

# 备份当前脚本
if [ -f "$SCRIPT_PATH" ]; then
    echo "Backing up current script..."
    cp "$SCRIPT_PATH" "$BACKUP_PATH"
fi

# 从GitHub下载最新脚本
echo "Downloading latest script from GitHub..."
if curl -sSL -f "$GITHUB_RAW_URL" -o "$SCRIPT_PATH.tmp" 2>/dev/null; then
    mv "$SCRIPT_PATH.tmp" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo "✓ Script updated successfully"
else
    echo "✗ Failed to download script from GitHub"
    if [ -f "$BACKUP_PATH" ]; then
        echo "Restoring backup..."
        cp "$BACKUP_PATH" "$SCRIPT_PATH"
    fi
    echo "Using existing script..."
fi

echo ""
echo "Running speedtest..."
echo ""

# 执行测速
cd /var/lib/vastai_kaalia/ && python3 ./send_mach_info.py --speedtest

EXIT_CODE=$?

echo ""
echo "=== Completed at $(date) ==="
echo "Exit code: $EXIT_CODE"

exit $EXIT_CODE
UPDATE_SCRIPT_EOF

chmod +x "$UPDATE_SCRIPT"
echo -e "${GREEN}✓ 更新脚本已创建${NC}"

echo ""
echo -e "${YELLOW}[5/7] 创建手动执行脚本...${NC}"

# 创建手动执行脚本（带实时输出）
MANUAL_SCRIPT="/var/lib/vastai_kaalia/manual_speedtest.sh"
cat > "$MANUAL_SCRIPT" << 'MANUAL_SCRIPT_EOF'
#!/bin/bash

# 手动执行测速脚本 - 带实时输出

echo "=== 手动触发测速 ==="
echo "Time: $(date)"
echo ""

# 启动服务
echo "启动测速服务..."
systemctl start vastai-speedtest.service

# 等待服务启动
sleep 1

# 实时显示日志
echo ""
echo "=== 执行日志 ==="
echo ""

# 使用 journalctl -f 实时跟踪，直到服务完成
timeout 120 journalctl -u vastai-speedtest.service -f -n 0 &
JOURNAL_PID=$!

# 等待服务完成（最多2分钟）
COUNTER=0
while systemctl is-active --quiet vastai-speedtest.service && [ $COUNTER -lt 120 ]; do
    sleep 1
    ((COUNTER++))
done

# 再等待一秒确保日志输出完整
sleep 2

# 停止日志跟踪
kill $JOURNAL_PID 2>/dev/null

echo ""
echo "=== 测速完成 ==="
echo ""

# 显示最后的状态
systemctl status vastai-speedtest.service --no-pager -l | tail -n 20
MANUAL_SCRIPT_EOF

chmod +x "$MANUAL_SCRIPT"
echo -e "${GREEN}✓ 手动执行脚本已创建${NC}"

echo ""
echo -e "${YELLOW}[6/7] 创建 systemd 服务...${NC}"

# 创建 systemd service
cat > "$SERVICE_FILE" << 'SERVICE_EOF'
[Unit]
Description=Vast.ai Machine Info Reporter with Speedtest
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=/var/lib/vastai_kaalia
ExecStart=/bin/bash /var/lib/vastai_kaalia/update_and_run.sh
StandardOutput=journal
StandardError=journal
Restart=no

[Install]
WantedBy=multi-user.target
SERVICE_EOF

echo -e "${GREEN}✓ Systemd 服务已创建${NC}"

echo ""
echo -e "${YELLOW}[7/7] 创建定时器 (每天随机时间运行)...${NC}"

# 创建 systemd timer
cat > "$TIMER_FILE" << 'TIMER_EOF'
[Unit]
Description=Run Vast.ai speedtest once daily at random time
Requires=vastai-speedtest.service

[Timer]
OnCalendar=daily
RandomizedDelaySec=24h
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

echo -e "${GREEN}✓ 定时器已创建${NC}"

echo ""
echo -e "${YELLOW}启用并启动服务...${NC}"

# 重载 systemd
systemctl daemon-reload

# 启用定时器
systemctl enable vastai-speedtest.timer

# 启动定时器
systemctl start vastai-speedtest.timer

echo -e "${GREEN}✓ 服务已启用${NC}"

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ 安装完成！${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
echo ""

# 显示定时器状态
echo -e "${YELLOW}定时器状态:${NC}"
systemctl status vastai-speedtest.timer --no-pager | head -n 10
echo ""

echo -e "${YELLOW}下次运行时间:${NC}"
systemctl list-timers vastai-speedtest.timer --no-pager
echo ""

echo -e "${YELLOW}立即执行测速...${NC}"
echo ""
systemctl start vastai-speedtest.service
sleep 2
journalctl -u vastai-speedtest.service -n 50 --no-pager

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN}常用命令:${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}手动执行测速（推荐 - 自动更新+实时日志）:${NC}"
echo -e "  ${GREEN}/var/lib/vastai_kaalia/manual_speedtest.sh${NC}"
echo ""
echo -e "${YELLOW}手动执行测速（仅更新+测速）:${NC}"
echo -e "  ${GREEN}/var/lib/vastai_kaalia/update_and_run.sh${NC}"
echo ""
echo -e "${YELLOW}仅执行测速（不更新脚本）:${NC}"
echo -e "  ${GREEN}cd /var/lib/vastai_kaalia/ && python3 ./send_mach_info.py --speedtest${NC}"
echo ""
echo -e "${YELLOW}查看实时日志:${NC}"
echo -e "  ${GREEN}journalctl -u vastai-speedtest.service -f${NC}"
echo ""
echo -e "${YELLOW}查看定时器状态:${NC}"
echo -e "  ${GREEN}systemctl list-timers vastai-speedtest.timer${NC}"
echo ""
echo -e "${YELLOW}停止定时器:${NC}"
echo -e "  ${GREEN}systemctl stop vastai-speedtest.timer${NC}"
echo ""
echo -e "${YELLOW}重新配置VPS地址:${NC}"
echo -e "  ${GREEN}再次运行此脚本${NC}"
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
