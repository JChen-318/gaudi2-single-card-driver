#!/bin/bash
# ============================================================
# 测试:只加载主驱动(不加载 CN/RDMA 模块),看 HPU 是否能算
# 目的:判断内存踩踏是否来自 CN/NIC 子系统
# ============================================================
set -u
LOG=/home/user/test-nobs.log
exec > >(tee -a "$LOG") 2>&1
echo "=================================================="
echo "=== $(date) 测试:仅主驱动,无 RDMA ==="
echo "=================================================="

echo
echo "--- [1/5] 安全网 ---"
echo 1 > /proc/sys/kernel/nmi_watchdog
echo 1 > /proc/sys/kernel/panic_on_oops
echo 1 > /proc/sys/kernel/hardlockup_panic
echo 1 > /proc/sys/kernel/softlockup_panic
echo 1 > /proc/sys/kernel/hung_task_panic
echo 30 > /proc/sys/kernel/hung_task_timeout_secs
echo 20 > /proc/sys/kernel/panic
echo 8   > /proc/sys/kernel/printk
echo "  nmi=$(cat /proc/sys/kernel/nmi_watchdog) panic=$(cat /proc/sys/kernel/panic)"

echo
echo "--- [2/5] netconsole ---"
modprobe netconsole netconsole=6666@192.168.1.10/br0,6666@192.168.1.20/xx:xx:xx:xx:xx:xx 2>/dev/null
echo "<6>NOBS-TEST 测试开始:仅主驱动" > /dev/kmsg
dmesg 2>/dev/null | grep -i "netconsole: network logging started" | tail -1

echo
echo "--- [3/5] 撤黑名单,只加载 compat + habanalabs ---"
mv -f /etc/modprobe.d/blacklist-habana.conf /root/bl.off 2>/dev/null
rmmod habanalabs_en habanalabs_cn habanalabs_ib habanalabs 2>/dev/null
modprobe habanalabs_compat 2>/dev/null && echo "  habanalabs_compat OK"
echo "  加载主驱动(约50秒)..."
modprobe habanalabs
echo "  modprobe 退出码=$?"

echo
echo "--- [4/5] 状态 ---"
lsmod | grep -E '^habanalabs' || echo "  ⚠ 主驱动没加载"
echo "  --- 已加载模块 ---"
lsmod | grep habanalabs
echo "  --- aux 驱动(应为空,因为没加载 _cn/_en/_ib) ---"
ls /sys/bus/auxiliary/drivers/ 2>/dev/null | grep -i habana || echo "    (无)"
echo "  --- hbl_0 ---"
ls /sys/class/infiniband/ 2>/dev/null || echo "    (无 RDMA 设备 — 符合预期)"

echo
echo "--- [5/5] hl-smi ---"
hl-smi 2>&1 | sed -n '1,10p'

echo
echo "=================================================="
echo "=== 准备就绪,请在外部运行 HPU 测试 ==="
echo "=================================================="
