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
journalctl -u vastai-speedtest.service -f -n 0 &
JOURNAL_PID=$!

# 等待服务完成
while systemctl is-active --quiet vastai-speedtest.service; do
    sleep 1
done

# 再等待一秒确保日志输出完整
sleep 2

# 停止日志跟踪
kill $JOURNAL_PID 2>/dev/null

echo ""
echo "=== 测速完成 ==="
echo ""

# 显示最后的状态
systemctl status vastai-speedtest.service --no-pager -l
