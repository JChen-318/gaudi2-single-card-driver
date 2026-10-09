#!/bin/bash
# =============================================================================
# Intel Gaudi2 (HL-225) 驱动补丁脚本
#
# 用途：升级 habanalabs-dkms 后，自动重打 3~4 处必需补丁
# 用法：sudo /root/patch-habanalabs.sh
#
# 背景：本卡硬件报告 SerDes type = 0xFFFF (UNKNOWN_SERDES_TYPE)，
#       官方驱动会因此拒绝初始化。本脚本绕过该限制。
# =============================================================================
set -e

echo "=================================================================="
echo " Intel Gaudi2 (HL-225) 驱动补丁"
echo "=================================================================="

# --- 定位源码目录 ---
S=$(ls -d /usr/src/habanalabs-* 2>/dev/null | grep -vE '\.bak$|\.ORIG$' | head -1)
if [ -z "$S" ]; then
    echo "ERROR: 找不到 /usr/src/habanalabs-* 源码目录" >&2
    echo "       请先安装 habanalabs-dkms" >&2
    exit 1
fi
echo "源码目录: $S"

F=$S/drivers/accel/habanalabs/gaudi2/gaudi2_cn.c
H=$S/drivers/accel/habanalabs/gaudi2/gaudi2_hbm_bringup.c

[ -f "$F" ] || { echo "ERROR: 找不到 $F" >&2; exit 1; }

# --- 备份 ---
if [ ! -f "$F.ORIG" ]; then
    cp "$F" "$F.ORIG"
    echo "已备份原始文件 -> $F.ORIG"
else
    echo "备份已存在: $F.ORIG"
fi

# --- 补丁①②：server_type + 绕过 bad SerDes ---
echo
echo "[补丁①②] server_type + 绕过 bad SerDes 检查"

if grep -q 'PATCHED' "$F"; then
    echo "  已存在 PATCHED 标记，跳过"
else
    # ① server_type: UNKNOWN -> GAUDI2_HLS2
    sed -i 's/hdev->asic_prop\.server_type = HL_SERVER_TYPE_UNKNOWN;/hdev->asic_prop.server_type = HL_SERVER_GAUDI2_HLS2; \/*PATCHED*\//' "$F"

    # ② return -EFAULT -> dev_warn（注意：不要用 \n，dev_warn 自带换行）
    sed -i 's/^\(\s*\)return -EFAULT;$/\1dev_warn(hdev->dev, "PATCHED-ignore-bad-serdes");/' "$F"

    if grep -q 'PATCHED' "$F"; then
        echo "  OK"
    else
        echo "  WARNING: 未匹配到目标代码，请手动检查" >&2
    fi
fi

# --- 补丁③：link_mask=0 时不清零 ports_mask ---
echo
echo "[补丁③] FW link_mask=0 时保留 driver ports_mask"

python3 - "$F" <<'PYEOF'
import sys, re
path = sys.argv[1]
src = open(path).read()

if 'PATCHED: FW link_mask=0' in src:
    print("  已应用，跳过")
    sys.exit(0)

OLD = """\t\t} else {
\t\t\thdev->cn.ports_mask &= cn_cpucp_info->link_mask[0];
\t\t\thdev->cn.ports_ext_mask &= cn_cpucp_info->link_ext_mask[0];
\t\t\thdev->cn.auto_neg_mask &= cn_cpucp_info->auto_neg_mask[0];
\t\t}"""

NEW = """\t\t} else {
\t\t\t/* PATCHED: FW link_mask=0 when SerDes unknown; zeroing ports_mask
\t\t\t * makes hl_cn_init() bail out early (no aux dev -> no netdev ->
\t\t\t * no RDMA -> HCL ibv init fails). Keep driver mask in that case. */
\t\t\tif (cn_cpucp_info->link_mask[0]) {
\t\t\t\thdev->cn.ports_mask     &= cn_cpucp_info->link_mask[0];
\t\t\t\thdev->cn.ports_ext_mask &= cn_cpucp_info->link_ext_mask[0];
\t\t\t\thdev->cn.auto_neg_mask  &= cn_cpucp_info->auto_neg_mask[0];
\t\t\t} else {
\t\t\t\tdev_warn(hdev->dev,
\t\t\t\t\t"PATCHED: FW link_mask=0, keeping ports_mask=0x%llx",
\t\t\t\t\t(unsigned long long)hdev->cn.ports_mask);
\t\t\t}
\t\t}"""

if OLD in src:
    open(path, 'w').write(src.replace(OLD, NEW, 1))
    print("  OK")
else:
    print("  WARNING: 未匹配（可能版本不同或已打过）", file=sys.stderr)
    # 尝试用正则宽松匹配
    pat = re.compile(
        r'\}\s*else\s*\{\s*'
        r'hdev->cn\.ports_mask\s*&=\s*cn_cpucp_info->link_mask\[0\];\s*'
        r'hdev->cn\.ports_ext_mask\s*&=\s*cn_cpucp_info->link_ext_mask\[0\];\s*'
        r'hdev->cn\.auto_neg_mask\s*&=\s*cn_cpucp_info->auto_neg_mask\[0\];\s*\}',
        re.S)
    if pat.search(src):
        print("  (正则匹配到，但缩进不同，请手动修改)", file=sys.stderr)
    sys.exit(1)
PYEOF

# --- 补丁④：kernel 6.8 的 MIN/MAX 宏冲突（仅旧版驱动需要） ---
echo
echo "[补丁④] 移除与 kernel 6.8 冲突的 MIN/MAX 宏"
if [ -f "$H" ]; then
    if grep -q '^#define MIN(a, b)' "$H" 2>/dev/null; then
        [ -f "$H.ORIG" ] || cp "$H" "$H.ORIG"
        sed -i '/^#define MIN(a, b)/d; /^#define MAX(a, b)/d' "$H"
        echo "  OK（已删除冲突宏定义）"
    else
        echo "  无需处理（未发现冲突宏）"
    fi
else
    echo "  跳过（文件不存在）"
fi

# --- 校验 ---
echo
echo "=================================================================="
echo " 校验结果"
echo "=================================================================="
echo "--- 补丁标记 ---"
grep -n 'PATCHED' "$F" || echo "  (未找到 PATCHED 标记)"

echo
echo "--- 补丁③ 上下文 ---"
grep -n -A14 'PATTERN_DUMMY\|PATCHED: FW link_mask=0' "$F" 2>/dev/null | head -20 || true

echo
echo "=================================================================="
echo " 下一步：重新编译并加载驱动"
echo "=================================================================="
VER=$(basename "$S" | sed 's/^habanalabs-//')
cat <<EOF

  sudo dkms build  habanalabs/${VER} -k \$(uname -r) --force
  sudo dkms install habanalabs/${VER} -k \$(uname -r) --force

  sudo rmmod habanalabs_ib habanalabs_en habanalabs_cn habanalabs 2>/dev/null
  sleep 3
  sudo modprobe habanalabs_cn
  sudo modprobe habanalabs_en
  sudo modprobe habanalabs_ib
  sudo modprobe habanalabs        # 等 50 秒
  sleep 50

  # 验证
  ls /sys/bus/auxiliary/devices/          # 期望 3 个
  ls /sys/class/infiniband/               # 期望 hbl_0
  cat /sys/class/infiniband/hbl_0/ext_ports_mask   # 期望 0

EOF

echo "完成。"
