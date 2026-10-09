#!/bin/bash
# ============================================================
# Gaudi 软件栈升级: 1.18.0-524  →  1.24.1-482
# 用途: 为安装 1Cat-vLLM-Gaudi (要求 Gaudi 1.24.1 + torch 2.11) 做准备
# 备份: /root/gaudi-backup-1.18.0/
# ============================================================
set -u
export DEBIAN_FRONTEND=noninteractive
LOG=/root/upgrade-1.24.1.log
exec > >(tee -a "$LOG") 2>&1
echo "=============================================="
echo "=== $(date) 开始升级 Gaudi 1.18.0 → 1.24.1 ==="
echo "=============================================="

echo
echo "--- [1/7] 卸载驱动模块 ---"
for m in habanalabs_ib habanalabs_en habanalabs_cn habanalabs; do
  if rmmod "$m" 2>/dev/null; then echo "  已卸载 $m"; else echo "  $m 未加载(跳过)"; fi
done

echo
echo "--- [2/7] 检查可用版本 ---"
echo "habanalabs-dkms 可用版本:"
apt-cache madison habanalabs-dkms 2>/dev/null | awk '{print "  "$2" "$3}' | head -6
echo "habanalabs-rdma-core 可用版本:"
apt-cache madison habanalabs-rdma-core 2>/dev/null | awk '{print "  "$2" "$3}' | head -6

echo
echo "--- [3/7] 卸载 1.18.0 软件栈 ---"
apt-get remove -y --purge \
    habanalabs-dkms habanalabs-firmware habanalabs-firmware-odm \
    habanalabs-firmware-tools habanalabs-graph habanalabs-qual \
    habanalabs-thunk 2>&1 | tail -8

echo
echo "--- [4/7] 安装 1.24.1-482 软件栈 ---"
# 先确定 rdma-core 的 1.24.1 版本号(若无则用最新)
RDMA_VER=$(apt-cache madison habanalabs-rdma-core 2>/dev/null | awk '{print $2}' | grep -m1 '1\.24\.1' || true)
PKGS="habanalabs-dkms=1.24.1-482
habanalabs-firmware=1.24.1-482
habanalabs-firmware-odm=1.24.1-482
habanalabs-firmware-tools=1.24.1-482
habanalabs-graph=1.24.1-482
habanalabs-qual=1.24.1-482
habanalabs-thunk=1.24.1-482"
if [ -n "$RDMA_VER" ]; then
    echo "  rdma-core 将安装 1.24.1 版本: $RDMA_VER"
    PKGS="$PKGS
habanalabs-rdma-core=$RDMA_VER"
else
    echo "  ⚠ 未找到 habanalabs-rdma-core 1.24.1,保持现有版本"
fi

echo "$PKGS" | tr '\n' ' '; echo
# shellcheck disable=SC2086
apt-get install -y --allow-downgrades $PKGS 2>&1 | tail -30

echo
echo "--- [5/7] DKMS 构建状态 ---"
dkms status 2>&1

echo
echo "--- [6/7] 安装后包版本 ---"
dpkg -l | grep -E '^ii.*habanalabs' | awk '{printf "  %-32s %s\n", $2, $3}'

echo
echo "--- [7/7] 源码目录 ---"
if [ -d /usr/src/habanalabs-1.24.1-482 ]; then
    echo "  ✅ /usr/src/habanalabs-1.24.1-482"
    echo "  gaudi2_cn.c 行数: $(wc -l < /usr/src/habanalabs-1.24.1-482/drivers/accel/habanalabs/gaudi2/gaudi2_cn.c 2>/dev/null)"
else
    echo "  ❌ 源码目录不存在!"
    ls -d /usr/src/habanalabs-* 2>/dev/null
fi

echo
echo "=============================================="
echo "=== $(date) 升级阶段完成 ==="
echo "=== 日志: $LOG ==="
echo "=============================================="
