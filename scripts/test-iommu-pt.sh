#!/bin/bash
# ============================================================
# 方案A:iommu 域改 identity + 恢复 HR 页表(1.24.1 原生配置)
# ============================================================
set -u
LOG=/home/user/test-iommu-pt.log
exec > >(tee -a "$LOG") 2>&1
echo "=================================================="
echo "=== $(date) 方案A:iommu identity + HR 页表 ==="
echo "=================================================="

echo
echo "--- [1/6] 还原补丁⑤(恢复 host_resident = 1) ---"
python3 /home/user/patch-hr-pgt.py --revert
echo
echo "  当前 gaudi2.c 的 host_resident:"
grep -n 'pmmu.host_resident\|dmmu.host_resident' /usr/src/habanalabs-1.24.1-482/drivers/accel/habanalabs/gaudi2/gaudi2.c | head -4

echo
echo "--- [2/6] 重新编译 DKMS ---"
dkms remove habanalabs/1.24.1-482 -k 6.8.0-136-generic --force 2>&1 | tail -1
dkms build habanalabs/1.24.1-482 -k 6.8.0-136-generic --force 2>&1 | tail -4
dkms install habanalabs/1.24.1-482 -k 6.8.0-136-generic 2>&1 | tail -2
echo "  模块:"
ls -la /var/lib/dkms/habanalabs/1.24.1-482/6.8.0-136-generic/x86_64/module/habanalabs.ko.zst

echo
echo "--- [3/6] ★ 设置 IOMMU 域为 identity ---"
echo -n "  当前: "; cat /sys/kernel/iommu_groups/33/type
echo identity > /sys/kernel/iommu_groups/33/type
echo -n "  改后: "; cat /sys/kernel/iommu_groups/33/type
echo -n "  设备视图: "; cat /sys/bus/pci/devices/0000:02:00.0/iommu_group/type

echo
echo "--- [4/6] 安全网 ---"
echo 1 > /proc/sys/kernel/nmi_watchdog
echo 1 > /proc/sys/kernel/panic_on_oops
echo 1 > /proc/sys/kernel/hardlockup_panic
echo 1 > /proc/sys/kernel/softlockup_panic
echo 1 > /proc/sys/kernel/hung_task_panic
echo 30 > /proc/sys/kernel/hung_task_timeout_secs
echo 20 > /proc/sys/kernel/panic
echo 8   > /proc/sys/kernel/printk
modprobe netconsole netconsole=6666@192.168.1.10/br0,6666@192.168.1.20/xx:xx:xx:xx:xx:xx 2>/dev/null
echo "<6>IOMMU-PT-TEST 开始:域=identity + HR 页表" > /dev/kmsg
echo "  安全网就绪"

echo
echo "--- [5/6] 撤黑名单,加载驱动 ---"
mv -f /etc/modprobe.d/blacklist-habana.conf /root/bl.off 2>/dev/null
for m in habanalabs_ib habanalabs_en habanalabs_cn habanalabs habanalabs_compat; do rmmod $m 2>/dev/null; done
modprobe habanalabs_compat 2>/dev/null && echo "  compat OK"
modprobe habanalabs_cn  2>/dev/null && echo "  cn OK"
modprobe habanalabs_en  2>/dev/null && echo "  en OK"
modprobe habanalabs_ib  2>/dev/null && echo "  ib OK"
echo "  加载主驱动(约50秒)..."
modprobe habanalabs; echo "  退出码=$?"

echo
echo "--- [6/6] 状态 ---"
lsmod | grep -E '^habanalabs'
echo "  --- PATCHED 日志 ---"
dmesg 2>/dev/null | grep -E "PATCHED|Found GAUDI2|added device" | tail -6
echo "  --- 域类型(应为 identity) ---"
cat /sys/kernel/iommu_groups/33/type
echo
hl-smi 2>&1 | sed -n '1,10p'
echo
echo "=== 就绪,可以跑 HPU 测试 ==="
