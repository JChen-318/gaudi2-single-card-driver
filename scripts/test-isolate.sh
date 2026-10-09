#!/bin/bash
# ============================================================
# 隔离测试:黑名单掉 CN/EN/IB 辅助模块,只放行主驱动 habanalabs
# 目的:判断踩内存是否由 CN/NIC 子系统引起
# ============================================================
set -u
LOG=/home/user/test-isolate.log
exec > >(tee -a "$LOG") 2>&1
echo "=================================================="
echo "=== $(date) 隔离测试:只放行主驱动 ==="
echo "=================================================="

echo
echo "--- [1/5] 卸载所有 habanalabs 模块 ---"
for m in habanalabs_ib habanalabs_en habanalabs_cn habanalabs habanalabs_compat; do
    rmmod "$m" 2>/dev/null && echo "  已卸 $m" || true
done
sleep 1
lsmod | grep habanalabs || echo "  ✅ 全部卸载"

echo
echo "--- [2/5] 只黑名单辅助模块(放行主驱动) ---"
cat > /etc/modprobe.d/blacklist-habana-aux.conf <<'EOF'
# 只黑名单 CN/EN/IB 辅助模块,主驱动 habanalabs 可正常加载
blacklist habanalabs_cn
blacklist habanalabs_en
blacklist habanalabs_ib
EOF
rm -f /etc/modprobe.d/blacklist-habana.conf
echo "  已写入:"; cat /etc/modprobe.d/blacklist-habana-aux.conf

echo
echo "--- [3/5] 安全网 ---"
echo 1 > /proc/sys/kernel/nmi_watchdog
echo 1 > /proc/sys/kernel/panic_on_oops
echo 1 > /proc/sys/kernel/hardlockup_panic
echo 1 > /proc/sys/kernel/softlockup_panic
echo 1 > /proc/sys/kernel/hung_task_panic
echo 30 > /proc/sys/kernel/hung_task_timeout_secs
echo 20 > /proc/sys/kernel/panic
echo 8   > /proc/sys/kernel/printk
modprobe netconsole netconsole=6666@192.168.1.10/br0,6666@192.168.1.20/xx:xx:xx:xx:xx:xx 2>/dev/null
echo "<6>ISOLATE-TEST 开始:只加载主驱动,黑名单辅助模块" > /dev/kmsg
echo "  安全网就绪"

echo
echo "--- [4/5] 加载 compat + 主驱动 ---"
modprobe habanalabs_compat 2>/dev/null && echo "  compat OK"
echo "  加载主驱动(约50秒)..."
modprobe habanalabs; echo "  退出码=$?"

echo
echo "--- [5/5] 确认辅助模块确实没被加载 ---"
lsmod | grep habanalabs
echo "  --- 检查是否有 _cn/_en/_ib ---"
if lsmod | grep -qE 'habanalabs_(cn|en|ib) '; then
    echo "  ⚠ 辅助模块还是被加载了!"
else
    echo "  ✅ 辅助模块确实未加载 — 隔离成功"
fi
echo
echo "  --- aux 设备(主驱动创建,但没驱动绑定) ---"
ls /sys/bus/auxiliary/devices/ 2>/dev/null | grep -i habana || echo "    (无)"
echo
echo "  --- hl-smi ---"
hl-smi 2>&1 | sed -n '1,10p'
echo
echo "=================================================="
echo "=== 隔离环境就绪 ==="
echo "=================================================="
