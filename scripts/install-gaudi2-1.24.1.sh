#!/bin/bash
# ==============================================================================
#  Intel Gaudi2 (HL-225) 一键部署脚本 —— Gaudi 1.24.1 + PyTorch 2.11
# ==============================================================================
#
#  适用:HL-225 / HL-225H / HL-225C(OAM 模组 + OAM→PCIe 转接卡)
#        非 Intel 认证平台(如 Haswell-EP 等老平台)
#
#  本脚本封装的完整方案(5 项修复,全部经过实测验证):
#    ① 驱动补丁:server_type = HL_SERVER_GAUDI2_HLS2
#    ② 驱动补丁:忽略 bad SerDes type 0xFFFF
#    ③ 驱动补丁:固件 link_mask=0 时不清零 ports_mask(否则无 RDMA)
#    ④ 内核参数 iommu=pt  ★ 核心:修复 1.24.1 的 host-resident 页表 bug
#    ⑤ 模块参数 nic_ports_ext_mask=0
#
#  已验证:matmul 4096x4096 / relu / fwd+bwd 全部通过,重启后依然正常
#
#  用法:
#    sudo ./install-gaudi2.sh                  # 完整安装
#    sudo ./install-gaudi2.sh --skip-pytorch   # 只装驱动,不装 PyTorch
#    sudo ./install-gaudi2.sh --verify-only    # 只做验证,不改动系统
#    sudo ./install-gaudi2.sh --check-iommu    # 只检查/配置 iommu=pt
#    sudo ./install-gaudi2.sh --help
#
#  回滚:见 Gaudi2-1.24.1-完整解决方案.md §7
# ==============================================================================

set -o pipefail

# ---------------------------- 配置区 ------------------------------------------
GAUDI_VER="1.24.1"
GAUDI_REV="482"
PT_VER="2.11.0"
PT_BUILD="009b5f6"
TORCH_FORK="torch-${PT_VER}a0+git${PT_BUILD}-cp312-cp312-linux_x86_64.whl"
PT_TGZ_URL="https://vault.habana.ai/artifactory/gaudi-pt-modules/${GAUDI_VER}/${GAUDI_REV}/pytorch/ubuntu2404/pytorch_modules-v${PT_VER}_${GAUDI_VER}_${GAUDI_REV}.tgz"
PKGS="habanalabs-dkms habanalabs-firmware habanalabs-firmware-odm habanalabs-firmware-tools habanalabs-graph habanalabs-qual habanalabs-thunk"
WORKDIR="/opt/gaudi-install"
LOG="${WORKDIR}/install-$(date +%Y%m%d-%H%M%S).log"

# ---------------------------- 参数解析 ----------------------------------------
SKIP_PYTORCH=0
VERIFY_ONLY=0
CHECK_IOMMU_ONLY=0
for a in "$@"; do
    case "$a" in
        --skip-pytorch) SKIP_PYTORCH=1 ;;
        --verify-only)  VERIFY_ONLY=1 ;;
        --check-iommu)  CHECK_IOMMU_ONLY=1 ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "未知参数: $a  (用 --help 查看用法)"; exit 1 ;;
    esac
done

# ---------------------------- 工具函数 ----------------------------------------
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;36m'; N='\033[0m'
ok()   { echo -e "  ${G}✅${N} $*"; }
bad()  { echo -e "  ${R}❌${N} $*"; }
warn() { echo -e "  ${Y}⚠️ ${N} $*"; }
info() { echo -e "  ${B}ℹ️ ${N} $*"; }
hdr()  { echo; echo -e "${B}──────────────────────────────────────────────────────────────${N}"; \
         echo -e "${B}  $*${N}"; \
         echo -e "${B}──────────────────────────────────────────────────────────────${N}"; }
die()  { bad "$*"; echo; echo "  日志: $LOG"; exit 1; }

SUDO=""
[ "$(id -u)" != "0" ] && SUDO="sudo"

# ---------------------------- 启动 --------------------------------------------
if [ "$VERIFY_ONLY" = 0 ] && [ "$CHECK_IOMMU_ONLY" = 0 ]; then
    $SUDO mkdir -p "$WORKDIR" 2>/dev/null
    $SUDO chmod 777 "$WORKDIR" 2>/dev/null
    exec > >(tee -a "$LOG") 2>&1
fi

cat <<'BANNER'
╔══════════════════════════════════════════════════════════════════════════════╗
║   Intel Gaudi2 (HL-225) 一键部署 —— Gaudi 1.24.1 + PyTorch 2.11             ║
║   适用于 OAM 模组 + OAM→PCIe 转接卡,非 Intel 认证平台                        ║
╚══════════════════════════════════════════════════════════════════════════════╝
BANNER
echo "  开始时间: $(date)"
echo "  日志文件: $LOG"
echo

# ==============================================================================
# 阶段 0:环境预检
# ==============================================================================
hdr "阶段 0/10 · 环境预检"

# --- OS ---
if [ -r /etc/os-release ]; then
    . /etc/os-release
    info "系统: $PRETTY_NAME  (内核 $(uname -r))"
    case "$VERSION_ID" in
        24.04) ok "Ubuntu 24.04 —— 已验证通过" ;;
        22.04) warn "Ubuntu 22.04 —— 未实测,理论可用" ;;
        *)     warn "未在 $VERSION_ID 上验证过,继续但请留意" ;;
    esac
fi

# --- root ---
if [ "$(id -u)" != "0" ]; then
    warn "未以 root 运行,将处处使用 sudo"
fi

# --- Gaudi 卡是否在 PCIe 上 ---
DEVS=$(lspci -nn 2>/dev/null | grep -i '1da3:' || true)
if [ -z "$DEVS" ]; then
    bad "PCIe 上找不到 Gaudi 卡 [1da3:xxxx]"
    cat <<'EOF'

  请按以下顺序排查(详见 Gaudi2-硬件安装与LED诊断.md):

    1. ★ 检查 OAM 卡的固定螺丝是否拧紧  ← 最常见的原因!
    2. 看 PCB 上的两个 LED:
         · 横着的 LED = 检测电源   (黄色 → 检查 48V/54V 辅助供电)
         · 竖着的 LED = 检测识别   (黄色 → 没安装到位)
    3. 换 CPU 直连的 x16 槽(单路机器上挂 CPU2 的槽是死的)
    4. 确认 Bios 里该槽位未被禁用

EOF
    exit 1
fi
ok "找到 Gaudi 卡:"
echo "$DEVS" | sed 's/^/       /'

# --- 卡的 PCI 地址 ---
BDF=$(echo "$DEVS" | head -1 | awk '{print $1}')
info "主设备地址: $BDF"

# --- PCIe 链路宽度 ---
LNK=$(lspci -vv -s "$BDF" 2>/dev/null | grep -oP 'LnkSta:.*?(?=,.*LnkSta)' | head -1)
LNKW=$(echo "$LNK" | grep -oP 'Width x\K[0-9]+' | head -1)
if [ -n "$LNKW" ]; then
    if [ "$LNKW" = "0" ]; then
        bad "PCIe 链路宽度 x0 —— 卡没有被正常链路!"
        echo "       → 先拧紧 OAM 卡螺丝,再看竖着的 LED(黄色=没装到位)"
        exit 1
    else
        ok "PCIe 链路: $(echo "$LNK" | sed 's/LnkSta: //')"
        [ "$LNKW" -lt 8 ] && warn "链路宽度偏窄(x$LNKW),性能会受影响"
    fi
else
    warn "读不到 LnkSta(可能需要 root)"
fi

# --- 现有版本 ---
CUR_DKMS=$(dpkg -l 2>/dev/null | awk '/^ii +habanalabs-dkms/{print $3}' | head -1)
if [ -n "$CUR_DKMS" ]; then
    info "当前已装 habanalabs-dkms: $CUR_DKMS"
    if [ "$CUR_DKMS" = "${GAUDI_VER}-${GAUDI_REV}" ]; then
        ok "已经是目标版本 ${GAUDI_VER}-${GAUDI_REV}(脚本会幂等处理)"
    fi
else
    info "当前未安装 habanalabs-dkms"
fi

# --- 磁盘空间 ---
AVAIL_MB=$(df -m /usr/src 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "$AVAIL_MB" ]; then
    if [ "$AVAIL_MB" -lt 3000 ]; then
        warn "磁盘仅剩 ${AVAIL_MB}MB,建议至少 3GB(编译 + 下载)"
    else
        ok "磁盘剩余 $((AVAIL_MB/1024))GB"
    fi
fi

# --- 编译工具 ---
MISS=""
for t in gcc make dkms dpkg-deb curl; do
    command -v "$t" >/dev/null 2>&1 || MISS="$MISS $t"
done
[ -n "$MISS" ] && die "缺少工具:$MISS  (安装:sudo apt install -y$MISS)"
ok "编译工具就绪 (gcc / make / dkms / curl)"

# --- Python ---
PY=python3.12
command -v $PY >/dev/null 2>&1 || PY=python3
PYV=$($PY -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)
info "Python: $PYV ($PY)"
case "$PYV" in
    3.12) ok "Python 3.12 —— 与官方 cp312 轮子匹配" ;;
    3.10|3.11) ok "Python $PYV —— 官方也提供对应轮子" ;;
    *) warn "Python $PYV —— 官方轮子是 cp312/cp310/cp311,可能不匹配" ;;
esac

# ==============================================================================
# 阶段 1:IOMMU 配置(★ 核心修复)
# ==============================================================================
hdr "阶段 1/10 · IOMMU 配置(★ 必须 iommu=pt)"

IOMMU_GROUP=$(basename "$(readlink -f /sys/bus/pci/devices/$BDF/iommu_group 2>/dev/null)" 2>/dev/null)
[ -n "$IOMMU_GROUP" ] && info "Gaudi 卡在 IOMMU 组 $IOMMU_GROUP"

CMDLINE=$(cat /proc/cmdline)
HAS_PT=0
echo "$CMDLINE" | grep -qw 'iommu=pt' && HAS_PT=1

if [ "$HAS_PT" = "1" ]; then
    ok "内核已带 iommu=pt"
    if [ -n "$IOMMU_GROUP" ]; then
        DOM=$(cat "/sys/kernel/iommu_groups/$IOMMU_GROUP/type" 2>/dev/null)
        if [ "$DOM" = "identity" ]; then
            ok "IOMMU 域类型 = identity  ★ 核心修复已生效"
        else
            warn "IOMMU 域类型 = $DOM(期望 identity)"
            info "尝试运行时改为 identity..."
            $SUDO bash -c "echo identity > /sys/kernel/iommu_groups/$IOMMU_GROUP/type" 2>/dev/null \
                && ok "已改为 identity" || warn "改不了(驱动可能已绑定),重启后由 iommu=pt 生效"
        fi
    fi
else
    bad "内核启动参数缺少 iommu=pt"
    cat <<'EOF'

  ┌────────────────────────────────────────────────────────────────────────┐
  │  ⚠️  iommu=pt 是本方案的【核心修复】,不加的话:                          │
  │                                                                        │
  │     Gaudi 1.24.1 驱动会启用 host-resident PMMU 页表                    │
  │     → 在 IOMMU Translated 域下把 DMA 地址当物理地址用                  │
  │     → CPU 把 PTE 写到错误内存 → 踩坏页表 → 【内核 panic】              │
  │                                                                        │
  │  (1.18.0 没有这个机制所以不崩;1.24.1 必崩,已复现 7 次)                 │
  └────────────────────────────────────────────────────────────────────────┘

EOF
    if [ "$VERIFY_ONLY" = 1 ] || [ "$CHECK_IOMMU_ONLY" = 1 ]; then
        die "缺少 iommu=pt —— 验证失败"
    fi

    read -r -p "  是否现在自动添加 iommu=pt 到 GRUB?(需要重启) [y/N] " ans
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        GRUB=/etc/default/grub
        BK="/root/grub.backup-$(date +%Y%m%d-%H%M%S)"
        $SUDO cp "$GRUB" "$BK"
        ok "已备份原 GRUB 配置 → $BK"
        if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB"; then
            CUR=$($SUDO grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB" | sed 's/.*="\(.*\)"/\1/')
            NEW=$(echo "$CUR iommu=pt" | sed 's/^ *//;s/  */ /')
            $SUDO sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW\"|" "$GRUB"
        else
            echo "GRUB_CMDLINE_LINUX_DEFAULT=\"iommu=pt\"" | $SUDO tee -a "$GRUB" >/dev/null
        fi
        $SUDO grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB" | sed 's/^/       /'
        $SUDO update-grub 2>&1 | tail -3 | sed 's/^/       /'
        ok "GRUB 已更新(含 iommu=pt)"
        echo
        warn "════════ 需要重启才能生效 ════════"
        echo "       重启后请再次运行本脚本继续安装:"
        echo "         sudo $0"
        echo
        read -r -p "  现在就重启? [y/N] " rb
        if [ "$rb" = "y" ] || [ "$rb" = "Y" ]; then
            info "同步磁盘后重启..."
            sync
            $SUDO systemctl reboot
        else
            info "已跳过重启。记得稍后手动重启再跑本脚本。"
        fi
        exit 0
    else
        die "用户取消。请手动在 /etc/default/grub 添加 iommu=pt 后 reboot"
    fi
fi

if [ "$CHECK_IOMMU_ONLY" = 1 ]; then
    echo; ok "IOMMU 检查完成"; exit 0
fi

# ==============================================================================
# 阶段 2:安装 Gaudi 1.24.1 软件栈
# ==============================================================================
hdr "阶段 2/10 · 安装 Gaudi ${GAUDI_VER} 软件栈"

if [ "$VERIFY_ONLY" = 1 ]; then
    info "--verify-only:跳过安装"
else
    # --- apt 源 ---
    LIST=/etc/apt/sources.list.d/habanalabs_synapseai.list
    if [ ! -f "$LIST" ]; then
        info "添加 Habana apt 源..."
        echo "deb https://vault.habana.ai/artifactory/debian noble main" | $SUDO tee "$LIST" >/dev/null
    fi
    ok "apt 源已就绪: $($SUDO cat $LIST | grep -v '^#' | head -1)"

    # --- 代理提示 ---
    if [ -n "${http_proxy:-}${https_proxy:-}" ]; then
        info "检测到代理: ${https_proxy:-$http_proxy}"
    fi
    info "提示: vault.habana.ai 会 302 跳转到 AWS S3。"
    info "      如果下载超时,请把 apt 代理配成【全局】(见文档 §3.1)"

    # --- 卸载旧版本 ---
    INSTALLED=$(dpkg -l 2>/dev/null | awk '/^ii +habanalabs/{print $2}' | tr '\n' ' ')
    if [ -n "$INSTALLED" ]; then
        info "已装:$INSTALLED"
        info "卸载已有版本..."
        $SUDO apt-get remove -y --purge $PKGS 2>&1 | tail -3 | sed 's/^/       /'
    fi

    # --- 安装 ---
    info "apt-get update ..."
    $SUDO apt-get update -qq 2>&1 | tail -2 | sed 's/^/       /' || warn "apt update 有告警"

    SPEC=""
    for p in $PKGS; do SPEC="$SPEC $p=${GAUDI_VER}-${GAUDI_REV}"; done
    info "安装:$SPEC"
    if ! $SUDO apt-get install -y --allow-downgrades $SPEC 2>&1 | tail -15 | sed 's/^/       /'; then
        die "安装失败。常见原因:
       1. apt 代理未覆盖 S3 跳转 → 配【全局】代理
       2. vault.habana.ai 不可达
       可尝试:https://vault.habana.ai/artifactory/debian 的 .deb 手动下载"
    fi

    NEWVER=$(dpkg -l 2>/dev/null | awk '/^ii +habanalabs-dkms/{print $3}' | head -1)
    [ "$NEWVER" = "${GAUDI_VER}-${GAUDI_REV}" ] && ok "已安装 habanalabs-dkms $NEWVER" \
        || warn "安装后版本为 $NEWVER(期望 ${GAUDI_VER}-${GAUDI_REV})"
fi

# --- 定位源码目录 ---
SRC=""
for d in /usr/src/habanalabs-*; do
    [ -d "$d/drivers" ] || continue
    case "$d" in *.bak|*ORIG*) continue;; esac
    SRC="$d"
done
[ -z "$SRC" ] && die "找不到 habanalabs 源码目录 /usr/src/habanalabs-*/drivers"
ok "源码目录: $SRC"

CN="$SRC/drivers/accel/habanalabs/gaudi2/gaudi2_cn.c"
G2="$SRC/drivers/accel/habanalabs/gaudi2/gaudi2.c"
[ -f "$CN" ] || die "找不到 $CN"

# ==============================================================================
# 阶段 3:应用 3 处驱动补丁
# ==============================================================================
hdr "阶段 3/10 · 应用驱动补丁(① SerDes ② server_type ③ ports_mask)"

if [ "$VERIFY_ONLY" = 1 ]; then
    info "--verify-only:跳过打补丁"
else
    $SUDO python3 - "$CN" <<'PYEOF'
import sys, os, shutil
CN = sys.argv[1]
TAB = "\t"
bak = CN + ".ORIG"
if not os.path.exists(bak):
    shutil.copy2(CN, bak); print("  [备份] " + bak)
with open(CN, "rb") as f:
    t = f.read().decode("utf-8", errors="surrogateescape")
orig = t

P12_OLD = ("\tdefault:\n"
           "\t\thdev->asic_prop.server_type = HL_SERVER_TYPE_UNKNOWN;\n"
           "\n"
           "\t\t/* SW-169172: For HLS3 setup don't fail device init on invalid serdes_type. */\n"
           "\t\tif (get_from_fw && hdev->gaudi2_setup_type != GAUDI2_SETUP_TYPE_HLS3) {\n"
           "\t\t\thl_err(hdev, \"bad SerDes type %d\\n\", serdes_type);\n"
           "\t\t\treturn -EFAULT;\n"
           "\t\t}\n")
P12_NEW = ("\tdefault:\n"
           "\t\thdev->asic_prop.server_type = HL_SERVER_GAUDI2_HLS2; /*PATCHED*/\n"
           "\n"
           "\t\t/* SW-169172: For HLS3 setup don't fail device init on invalid serdes_type. */\n"
           "\t\tif (get_from_fw && hdev->gaudi2_setup_type != GAUDI2_SETUP_TYPE_HLS3) {\n"
           "\t\t\thl_err(hdev, \"bad SerDes type %d\\n\", serdes_type);\n"
           "\t\t\tdev_warn(hdev->dev, \"PATCHED-ignore-bad-serdes\");\n"
           "\t\t}\n")
P3_OLD = ("\t\t} else {\n"
          "\t\t\thdev->cn.ports_mask &= cn_cpucp_info->link_mask[0];\n"
          "\t\t\thdev->cn.ports_ext_mask &= cn_cpucp_info->link_ext_mask[0];\n"
          "\t\t\thdev->cn.auto_neg_mask &= cn_cpucp_info->auto_neg_mask[0];\n"
          "\t\t}\n")
P3_NEW = ("\t\t} else {\n"
          "\t\t\tif (cn_cpucp_info->link_mask[0]) {\n"
          "\t\t\t\thdev->cn.ports_mask &= cn_cpucp_info->link_mask[0];\n"
          "\t\t\t\thdev->cn.ports_ext_mask &= cn_cpucp_info->link_ext_mask[0];\n"
          "\t\t\t\thdev->cn.auto_neg_mask &= cn_cpucp_info->auto_neg_mask[0];\n"
          "\t\t\t} else {\n"
          "\t\t\t\tdev_warn(hdev->dev,\n"
          "\t\t\t\t\t\"PATCHED: FW link_mask=0, keeping ports_mask=0x%llx\",\n"
          "\t\t\t\t\t(unsigned long long)hdev->cn.ports_mask);\n"
          "\t\t\t}\n"
          "\t\t}\n")

# ①②
if "/*PATCHED*/" in t:
    print("  补丁 ①② 已存在,跳过")
elif t.count(P12_OLD) == 1:
    t = t.replace(P12_OLD, P12_NEW, 1); print("  补丁 ①② ✅ 已应用")
else:
    print("  补丁 ①② ❌ 未找到匹配(源码版本不符?)  count=%d" % t.count(P12_OLD))
# ③
if "PATCHED: FW link_mask=0" in t:
    print("  补丁 ③  已存在,跳过")
else:
    idx = t.rfind(P3_OLD)
    if idx >= 0:
        t = t[:idx] + P3_NEW + t[idx+len(P3_OLD):]; print("  补丁 ③  ✅ 已应用")
    else:
        print("  补丁 ③  ❌ 未找到匹配")

if t != orig:
    with open(CN, "wb") as f:
        f.write(t.encode("utf-8", errors="surrogateescape"))
    print("  [写入] 文件已更新")

# 校验
with open(CN, "rb") as f:
    c = f.read().decode("utf-8", errors="surrogateescape")
print("  --- 校验 ---")
print("    PATCHED 标记        : %d (期望 3)" % c.count("PATCHED"))
print("    server_type 已修正  : %s" % ("是" if "HL_SERVER_GAUDI2_HLS2" in c else "否"))
print("    bad SerDes 不再return: %s" % ("是" if "return -EFAULT" not in c else "否"))
a,b = c.count("{"), c.count("}")
print("    { } 配平            : %s (%d/%d)" % ("OK" if a==b else "✗", a, b))
PYEOF
    ok "补丁处理完成"
fi

# ==============================================================================
# 阶段 4:DKMS 编译 + 安装  ⚠️ 必须先 build 再 install
# ==============================================================================
hdr "阶段 4/10 · DKMS 编译(★ 必须 build --force,否则产生 0 字节模块)"

KVER=$(uname -r)
DVER="${GAUDI_VER}-${GAUDI_REV}"

if [ "$VERIFY_ONLY" = 1 ]; then
    info "--verify-only:跳过编译"
else
    info "卸载旧 DKMS 树..."
    $SUDO dkms remove "habanalabs/$DVER" -k "$KVER" --force >/dev/null 2>&1 || true

    info "编译中(约 30-60 秒)..."
    if ! $SUDO dkms build "habanalabs/$DVER" -k "$KVER" --force 2>&1 | tail -8 | sed 's/^/       /'; then
        die "DKMS 编译失败。常见原因:
       1. 补丁破坏了源码(检查 $CN 的 { } 配平)
       2. 内核头文件缺失: sudo apt install linux-headers-$KVER
       3. 旧内核的 MIN/MAX 宏冲突(1.24.1 已修复)"
    fi
    ok "编译完成"

    info "安装模块..."
    $SUDO dkms install "habanalabs/$DVER" -k "$KVER" 2>&1 | tail -3 | sed 's/^/       /'
fi

# --- ★ 关键检查:模块不能是 0 字节 ---
MODDIR="/var/lib/dkms/habanalabs/$DVER/$KVER"
KO=$(find "$MODDIR" -name 'habanalabs.ko*' 2>/dev/null | head -1)
[ -z "$KO" ] && KO="/lib/modules/$KVER/updates/dkms/habanalabs.ko.zst"
if [ -f "$KO" ]; then
    SZ=$(stat -c%s "$KO")
    if [ "$SZ" -lt 10000 ]; then
        bad "模块只有 $SZ 字节 —— 是空的!"
        die "说明 dkms install 之前没有真正编译。请手动执行:
       sudo dkms remove habanalabs/$DVER -k $KVER --force
       sudo dkms build  habanalabs/$DVER -k $KVER --force   ← 必须
       sudo dkms install habanalabs/$DVER -k $KVER"
    fi
    ok "模块大小正常:$((SZ/1024)) KB"
    # --- 补丁是否编入 ---
    if command -v zstd >/dev/null 2>&1; then
        PATCHED=$(zstd -dc "$KO" 2>/dev/null | strings | grep -c 'PATCHED')
        [ "$PATCHED" -ge 2 ] && ok "补丁已编入模块(PATCHED 标记 $PATCHED 处)" \
            || bad "模块里找不到 PATCHED 标记 —— 补丁可能没生效!"
    fi
else
    bad "找不到编译出的模块"
fi

# ==============================================================================
# 阶段 5:模块参数 + 开机自动加载
# ==============================================================================
hdr "阶段 5/10 · 模块参数与开机自动加载"

if [ "$VERIFY_ONLY" = 0 ]; then
    # --- 模块参数 ---
    OPT=/etc/modprobe.d/habanalabs-options.conf
    echo "options habanalabs nic_ports_ext_mask=0" | $SUDO tee "$OPT" >/dev/null
    ok "模块参数: $(cat $OPT)"
    info "  nic_ports_ext_mask=0 → 所有端口算 scale-up,让 SCAL 建起集群"
    warn "  不要加 card_type=0!(会把所有端口标成外部,抹掉 scale-up)"

    # --- 移除任何黑名单 ---
    for f in /etc/modprobe.d/blacklist-habana*.conf; do
        [ -f "$f" ] && { $SUDO mv "$f" "$f.disabled"; warn "发现黑名单 $f,已改名停用"; }
    done

    # --- 开机自动加载 ---
    ML=/etc/modules-load.d/habanalabs.conf
    printf '# Habana Gaudi 驱动加载顺序(aux 先,主模块后)\nhabanalabs_compat\nhabanalabs_cn\nhabanalabs_en\nhabanalabs_ib\nhabanalabs\n' \
        | $SUDO tee "$ML" >/dev/null
    ok "已配置开机自动加载: $ML"
fi

# --- 加载驱动 ---
hdr "阶段 6/10 · 加载驱动"

# 安全网(运行时)
$SUDO bash -c '
  echo 1  > /proc/sys/kernel/nmi_watchdog
  echo 1  > /proc/sys/kernel/hardlockup_panic 2>/dev/null || true
  echo 1  > /proc/sys/kernel/softlockup_panic 2>/dev/null || true
  echo 1  > /proc/sys/kernel/panic_on_oops
  echo 1  > /proc/sys/kernel/hung_task_panic 2>/dev/null || true
  echo 30 > /proc/sys/kernel/hung_task_timeout_secs 2>/dev/null || true
  echo 20 > /proc/sys/kernel/panic
' 2>/dev/null
ok "安全网已就绪(panic 后 20 秒自动重启)"

if [ "$VERIFY_ONLY" = 0 ]; then
    $SUDO bash -c "
      for m in habanalabs_ib habanalabs_en habanalabs_cn habanalabs habanalabs_compat; do
          rmmod \$m 2>/dev/null
      done
      modprobe habanalabs_compat 2>/dev/null
      modprobe habanalabs_cn  2>/dev/null
      modprobe habanalabs_en  2>/dev/null
      modprobe habanalabs_ib  2>/dev/null
      echo '  加载主驱动(约 50 秒,固件加载)...'
      modprobe habanalabs
      echo \"  退出码=\$?\"
    " 2>&1 | sed 's/^/  /'
fi

if lsmod | grep -q '^habanalabs '; then
    ok "主驱动已加载"
else
    bad "主驱动未加载!"
    echo "      排查: dmesg | tail -30"
    exit 1
fi

# --- 设备节点 ---
RDMA=$(ls /sys/class/infiniband/ 2>/dev/null | tr '\n' ' ')
AUX=$(ls /sys/bus/auxiliary/devices/ 2>/dev/null | grep -c habana)
[ -n "$RDMA" ] && ok "RDMA 设备: $RDMA" || warn "无 RDMA 设备(hbl_0 缺失)"
[ "$AUX" -ge 3 ] && ok "aux 设备: $AUX 个" || warn "aux 设备只有 $AUX 个(期望 3)"

if command -v hl-smi >/dev/null 2>&1; then
    echo
    hl-smi 2>&1 | sed -n '1,9p' | sed 's/^/  /'
fi

# ==============================================================================
# 阶段 7:安装 PyTorch 2.11 + habana 插件
# ==============================================================================
hdr "阶段 7/10 · 安装 PyTorch ${PT_VER} + habana ${GAUDI_VER}.${GAUDI_REV}"

if [ "$VERIFY_ONLY" = 1 ] || [ "$SKIP_PYTORCH" = 1 ]; then
    info "跳过 PyTorch 安装"
else
    PYD=$WORKDIR/pt
    $SUDO mkdir -p "$PYD"

    # --- 下载 ---
    TGZ="$PYD/pt.tgz"
    if [ ! -s "$TGZ" ]; then
        info "下载 PyTorch 模块包 (238MB)..."
        info "  $PT_TGZ_URL"
        if ! $SUDO curl -fSL --retry 3 -o "$TGZ" "$PT_TGZ_URL"; then
            bad "下载失败。若需代理: export https_proxy=http://<proxy>:<port>"
            die "无法下载 PyTorch 模块包"
        fi
    fi
    ok "模块包就绪: $(du -h $TGZ | cut -f1)"

    # --- 解压 ---
    [ -f "$PYD/install.sh" ] || $SUDO tar -xzf "$TGZ" -C "$PYD"
    [ -f "$PYD/install.sh" ] || die "解压失败"
    ok "已解压"

    PIP="$PY -m pip"

    # --- 清理旧版本(两个位置都要) ---
    info "清理旧 torch / habana ..."
    $SUDO $PIP uninstall -y torch torchvision torchaudio \
        habana_torch_plugin habana-torch-plugin habana_gpu_migration \
        habana-torch-dataloader habana-pyhlml 2>&1 | grep -E 'Successfully|not installed' | tail -5 | sed 's/^/       /' || true
    $SUDO rm -rf /usr/local/lib/python3.*/dist-packages/torch* \
                /usr/local/lib/python3.*/dist-packages/habana* 2>/dev/null || true
    for h in /home/*/.local/lib/python3.*/site-packages; do
        [ -d "$h" ] && $SUDO rm -rf "$h"/torch* "$h"/habana* 2>/dev/null
    done
    ok "已清理"

    # --- 1. habana-pyhlml ---
    info "[1/4] habana-pyhlml==${GAUDI_VER}.${GAUDI_REV} (来自 PyPI)"
    $SUDO $PIP install --disable-pip-version-check \
        "habana-pyhlml==${GAUDI_VER}.${GAUDI_REV}" 2>&1 | tail -3 | sed 's/^/       /'

    # --- 2. torchvision(它会拉上游 torch,没关系,下一步覆盖) ---
    info "[2/4] torchvision(会拉上游 torch,稍后被 Habana fork 覆盖)"
    $SUDO $PIP install --disable-pip-version-check --no-cache-dir \
        "torchvision==0.26.0" --index-url https://download.pytorch.org/whl/cpu \
        2>&1 | tail -3 | sed 's/^/       /' || warn "torchvision 安装失败(非致命)"

    # --- 3. ★ 本地 wheels,必须最后装 ---
    info "[3/4] ★ 本地 wheels(含 Habana torch)—— 必须最后装,覆盖上游 torch"
    $SUDO $PIP install --disable-pip-version-check --no-deps --force-reinstall \
        "$PYD/$TORCH_FORK" 2>&1 | tail -3 | sed 's/^/       /'
    $SUDO $PIP install --disable-pip-version-check --no-deps --force-reinstall \
        "$PYD"/habana_torch_plugin-*.whl "$PYD"/habana_gpu_migration-*.whl \
        "$PYD"/habana_torch_dataloader-*.whl "$PYD"/torch_tb_profiler-*.whl \
        "$PYD"/neural_compressor_pt-*.whl "$PYD"/intel_transformer_engine-*.whl \
        2>&1 | tail -4 | sed 's/^/       /'

    # --- 4. requirements ---
    info "[4/4] requirements-pytorch.txt"
    $SUDO $PIP install --disable-pip-version-check -r "$PYD/requirements-pytorch.txt" \
        2>&1 | tail -3 | sed 's/^/       /'

    # --- 加固:再装一次本地 torch ---
    $SUDO $PIP install --disable-pip-version-check --no-deps --force-reinstall \
        "$PYD/$TORCH_FORK" 2>&1 | tail -2 | sed 's/^/       /'

    # --- ★ 断言校验 ---
    VER=$($PY -c 'import torch;print(torch.__version__)' 2>/dev/null)
    if echo "$VER" | grep -q '+cpu'; then
        die "torch 被装成了上游 CPU 版($VER)—— 没有 HPU 支持!
       修复: sudo $PIP install --no-deps --force-reinstall $PYD/$TORCH_FORK"
    fi
    ok "torch = $VER  (Habana fork)"
fi

# ==============================================================================
# 阶段 8:环境变量 + 日志目录
# ==============================================================================
hdr "阶段 8/10 · 运行环境配置"

# 官方 profile.d(由 habanalabs-graph 提供)
if [ -f /etc/profile.d/habanalabs.sh ]; then
    ok "已存在 /etc/profile.d/habanalabs.sh"
else
    warn "缺少 /etc/profile.d/habanalabs.sh(应由 habanalabs-graph 提供)"
fi
grep -qs GC_KERNEL_PATH /etc/profile.d/habanalabs.sh 2>/dev/null \
    && ok "GC_KERNEL_PATH 已配置(图编译必需)" \
    || warn "GC_KERNEL_PATH 未配置 → 图编译会失败(status 26)"

$SUDO mkdir -p /var/log/habana_logs && $SUDO chmod 777 /var/log/habana_logs
ok "日志目录 /var/log/habana_logs 就绪"

# 便捷运行包装
$SUDO tee /usr/local/bin/hpu-run >/dev/null <<'EOS'
#!/bin/bash
# 在正确的 Gaudi 环境下运行命令
# 用法: hpu-run python3 your_script.py
exec bash -lc '
  source /etc/profile.d/habanalabs.sh 2>/dev/null
  export LD_PRELOAD=/lib/x86_64-linux-gnu/libtcmalloc.so.4
  "$@"
' -- "$@"
EOS
$SUDO chmod +x /usr/local/bin/hpu-run
ok "已安装便捷命令 /usr/local/bin/hpu-run"

# ==============================================================================
# 阶段 9:持久化与防护
# ==============================================================================
hdr "阶段 9/10 · 持久化与防护"

if [ "$VERIFY_ONLY" = 0 ]; then
    # --- panic 自动重启(持久) ---
    $SUDO tee /etc/sysctl.d/99-panic-reboot.conf >/dev/null <<'EOS'
# Gaudi 排查/运行期间的安全网:内核 panic 后 20 秒自动重启
# 否则机器会永久卡死,需要物理断电
kernel.panic = 20
kernel.panic_on_oops = 1
EOS
    ok "已配置 panic 自动重启: /etc/sysctl.d/99-panic-reboot.conf"

    # --- 锁定包版本(防 apt 升级覆盖补丁) ---
    $SUDO apt-mark hold $PKGS >/dev/null 2>&1
    ok "已 apt-mark hold 以下包(防升级覆盖补丁):"
    echo "       $(apt-mark showhold | grep habanalabs | tr '\n' ' ')"
fi

# --- 健康检查工具 ---
$SUDO tee /usr/local/bin/gaudi-check >/dev/null <<'EOS'
#!/bin/bash
# Gaudi2 健康检查 —— 关键项一眼看全
echo "=============================================="
echo "  Gaudi2 HL-225 (Gaudi 1.24.1) 健康检查"
echo "=============================================="
echo
echo "--- 1. 内核启动参数 ---"
if grep -q 'iommu=pt' /proc/cmdline; then echo "  ✅ iommu=pt 已生效"
else echo "  ❌ iommu=pt 缺失!(panic 会复发)"; fi
echo "     $(cut -c1-88 /proc/cmdline)"

echo
echo "--- 2. IOMMU 域类型(必须 identity) ---"
for d in /sys/bus/pci/devices/*/; do
    if lspci -nn -s "$(basename $d)" 2>/dev/null | grep -q 1da3:; then
        B=$(basename "$d")
        G=$(basename "$(readlink -f $d/iommu_group 2>/dev/null)" 2>/dev/null)
        T=$(cat /sys/kernel/iommu_groups/$G/type 2>/dev/null)
        echo "  设备 $B  组 $G  域: $T"
        [ "$T" = identity ] && echo "  ✅ identity" || echo "  ❌ 必须是 identity!"
    fi
done

echo
echo "--- 3. 驱动模块 ---"
lsmod | grep -E '^habanalabs' | awk '{printf "  %-22s %s\n",$1,$3}' || echo "  ⚠ 未加载"

echo
echo "--- 4. 设备节点 ---"
echo "  RDMA : $(ls /sys/class/infiniband/ 2>/dev/null | tr '\n' ' ')"
echo "  aux  : $(ls /sys/bus/auxiliary/devices/ 2>/dev/null | grep habana | tr '\n' ' ')"
echo "  节点 : $(ls /dev/accel/ 2>/dev/null | tr '\n' ' ')"

echo
echo "--- 5. panic 保护 ---"
echo "  kernel.panic  = $(cat /proc/sys/kernel/panic)   (0=不自动重启)"

echo
echo "--- 6. hl-smi ---"
hl-smi 2>&1 | sed -n '1,9p'

echo
echo "=============================================="
echo "  判定:第 1、2 项都是 ✅ 才算正常"
echo "=============================================="
EOS
$SUDO chmod +x /usr/local/bin/gaudi-check
ok "已安装健康检查 /usr/local/bin/gaudi-check"

# ==============================================================================
# 阶段 10:端到端验证
# ==============================================================================
hdr "阶段 10/10 · 端到端验证"

TESTF="$WORKDIR/hputest.py"
cat > "$TESTF" <<'EOS'
import torch, time, sys
import habana_frameworks.torch.hpu as hthpu
print("  torch      :", torch.__version__)
print("  HPU 可用   :", hthpu.is_available())
if not hthpu.is_available():
    print("  ❌ HPU 不可用"); sys.exit(1)
print("  HPU 数量   :", hthpu.device_count())
print("  设备名     :", hthpu.get_device_name(0))
d = "hpu"
t0 = time.time()
a = torch.randn(4096, 4096).to(d); b = torch.randn(4096, 4096).to(d)
print("  matmul     : sum=%.2f  (%.1fs)" % (a @ b).sum().item(), flush=True)
x = torch.randn(2048, 2048).to(d)
print("  relu       : sum=%.2f" % torch.relu(x).sum().item())
m = torch.nn.Sequential(torch.nn.Linear(1024,2048), torch.nn.ReLU(),
                        torch.nn.Linear(2048,10)).to(d)
opt = torch.optim.SGD(m.parameters(), lr=0.01)
inp = torch.randn(64,1024).to(d); tgt = torch.randint(0,10,(64,)).to(d)
loss = torch.nn.functional.cross_entropy(m(inp), tgt)
loss.backward(); opt.step()
print("  fwd+bwd    : loss=%.6f" % loss.item())
try:
    f, t = torch.hpu.mem_get_info()
    print("  显存       : %.1f GB / %.1f GB" % ((t-f)/1e9, t/1e9))
except Exception: pass
print("  RESULT: HPU WORKS")
EOS

if [ -r /etc/profile.d/habanalabs.sh ] && command -v $PY >/dev/null 2>&1; then
    OUT=$($SUDO bash -lc "
        source /etc/profile.d/habanalabs.sh
        export LD_PRELOAD=/lib/x86_64-linux-gnu/libtcmalloc.so.4
        cd $WORKDIR && timeout 300 $PY $TESTF 2>&1 | grep -vE 'add_step_closure|mark_step function'
    " 2>&1)
    echo "$OUT" | sed 's/^/  /'
    if echo "$OUT" | grep -q 'RESULT: HPU WORKS'; then
        echo
        echo -e "  ${G}╔══════════════════════════════════════════════════════════════╗${N}"
        echo -e "  ${G}║   🎉 部署成功!HPU 计算验证通过                              ║${N}"
        echo -e "  ${G}╚══════════════════════════════════════════════════════════════╝${N}"
        RC=0
    else
        echo
        bad "HPU 验证失败。排查步骤:"
        echo "       1. /usr/local/bin/gaudi-check      # 看 iommu 域是否 identity"
        echo "       2. dmesg | grep -i habanalabs      # 看内核报错"
        echo "       3. cat /var/log/habana_logs/synapse_runtime.log"
        echo "       4. cat /var/log/habana_logs/synapse_utils_log.txt"
        RC=1
    fi
else
    warn "跳过验证(缺少 profile.d 或 Python)"
    RC=0
fi

# ==============================================================================
echo
echo "════════════════════════════════════════════════════════════════════════════"
if [ "$RC" = "0" ]; then
    echo -e "${G}  ✅ 全部完成${N}"
else
    echo -e "${R}  ⚠️  部署完成但有验证失败项${N}"
fi
echo "════════════════════════════════════════════════════════════════════════════"
cat <<EOF

  常用命令:
    /usr/local/bin/gaudi-check          # 健康检查(随时跑)
    hpu-run python3 your_script.py      # 在正确环境下跑程序
    sudo hl-smi                         # 查看卡状态
    sudo dkms status                    # 驱动编译状态

  环境变量(跑 HPU 程序前必须):
    source /etc/profile.d/habanalabs.sh
    export LD_PRELOAD=/lib/x86_64-linux-gnu/libtcmalloc.so.4

  关键文件:
    模块参数    /etc/modprobe.d/habanalabs-options.conf
    自动加载    /etc/modules-load.d/habanalabs.conf
    panic 保护  /etc/sysctl.d/99-panic-reboot.conf
    日志        $LOG
    源码(含补丁) $SRC

  ⚠️  注意事项:
    · iommu=pt 是核心修复,不要从 GRUB 里删掉!
    · 已 apt-mark hold 相关包,不要 apt upgrade 它们
    · 镜像/备份:见 Gaudi2-1.24.1-完整解决方案.md §7

  日志: $LOG
  结束时间: $(date)
EOF
exit $RC
