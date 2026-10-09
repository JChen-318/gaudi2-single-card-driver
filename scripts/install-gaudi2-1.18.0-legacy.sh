#!/bin/bash
# =============================================================================
#  Intel Gaudi 2 (HL-225) 一键部署 / 修复脚本
#
#  功能：
#    1. 环境预检（OS / 内核 / 卡 / PCIe 链路）
#    2. 安装 Intel Gaudi 基础软件栈（驱动 + 固件 + 工具）
#    3. 打 3~4 处必需源码补丁（绕过 SerDes 校验 / 修复互联）
#    4. 配置模块参数 nic_ports_ext_mask=0
#    5. 编译并加载驱动 + 验证 RDMA 链路
#    6. 安装匹配版本的 PyTorch 栈
#    7. 配置运行环境（环境变量 + hpu-run 便捷命令）
#    8. 端到端验证
#
#  用法：
#    sudo ./install-gaudi2.sh                 # 完整部署
#    sudo ./install-gaudi2.sh --skip-pytorch  # 只装驱动
#    sudo ./install-gaudi2.sh --verify-only   # 只做验证
#    sudo ./install-gaudi2.sh --help
#
#  适用：Ubuntu 24.04 / kernel 6.8 / habanalabs 1.18.0
#        非 Intel 认证平台上的单张 Gaudi2 HL-225
# =============================================================================

set -o pipefail

# ----------------------------- 配置 ------------------------------------------
HABANA_VERSION="1.18.0"
RELEASE_ID="524"
PKG_VER="${HABANA_VERSION}-${RELEASE_ID}"        # 1.18.0-524
TORCH_VER="2.4.0"
PT_MODULES_TGZ="pytorch_modules-v2.4.0_${HABANA_VERSION}_${RELEASE_ID}.tgz"
HABANA_SERVER="vault.habana.ai"
WORKDIR="/tmp/gaudi2-install"
LOG="$WORKDIR/install.log"

DO_BASE=1
DO_PATCH=1
DO_PYTORCH=1
DO_VERIFY=1

# ----------------------------- 参数解析 --------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --version)      HABANA_VERSION="$2"; shift 2 ;;
        --release-id)   RELEASE_ID="$2";     shift 2 ;;
        --skip-base)    DO_BASE=0;    shift ;;
        --skip-patch)   DO_PATCH=0;   shift ;;
        --skip-pytorch) DO_PYTORCH=0; shift ;;
        --verify-only)  DO_BASE=0; DO_PATCH=0; DO_PYTORCH=0; DO_VERIFY=1; shift ;;
        -h|--help)      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done
PKG_VER="${HABANA_VERSION}-${RELEASE_ID}"
PT_MODULES_TGZ="pytorch_modules-v2.4.0_${HABANA_VERSION}_${RELEASE_ID}.tgz"

# ----------------------------- 工具函数 --------------------------------------
C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[0;33m'; C_B='\033[0;36m'; C_N='\033[0m'
STEP=0
step() { STEP=$((STEP+1)); echo; echo -e "${C_B}━━━ [$STEP] $* ━━━${C_N}"; }
ok()   { echo -e "  ${C_G}✅ $*${C_N}"; }
warn() { echo -e "  ${C_Y}⚠️  $*${C_N}"; }
err()  { echo -e "  ${C_R}❌ $*${C_N}"; }
info() { echo -e "  ℹ️  $*"; }
die()  { err "$*"; echo; err "部署中断，日志: $LOG"; exit 1; }

# 把所有输出同时写日志
mkdir -p "$WORKDIR"
exec > >(tee -a "$LOG") 2>&1

banner() {
    echo
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Intel Gaudi 2 (HL-225) 一键部署脚本"
    echo "  habanalabs ${PKG_VER}  /  torch ${TORCH_VER}"
    echo "  时间: $(date '+%F %T')"
    echo "═══════════════════════════════════════════════════════════════"
}

# ----------------------------- 预检 ------------------------------------------
preflight() {
    step "环境预检"

    [ "$(id -u)" -eq 0 ] || die "请用 sudo 运行"

    # OS
    . /etc/os-release
    if [ "$ID" != "ubuntu" ]; then warn "非 Ubuntu（$ID），脚本未测试"; fi
    info "系统: $PRETTY_NAME"
    if [ "${VERSION_ID}" != "24.04" ]; then
        warn "非 24.04（$VERSION_ID），补丁行号/包名可能不同"
    fi

    # 内核
    KVER=$(uname -r)
    info "内核: $KVER"
    [ -d "/lib/modules/$KVER/build" ] || die "缺少内核头文件: apt install linux-headers-$KVER"

    # 必要工具
    for t in dkms make gcc python3 curl; do
        command -v $t >/dev/null || die "缺少命令: $t"
    done
    info "构建工具齐全"

    # 网卡（这里只做提示，实际在 verify_rdma 里轮询检查）
    info "网络接口数: $(ip -o link show 2>/dev/null | wc -l)"

    # 找卡
    CARD=$(lspci -nnD 2>/dev/null | grep -i '1da3:1020' | cut -d' ' -f1 | head -1)
    if [ -z "$CARD" ]; then
        err "总线上找不到 Gaudi2 [1da3:1020]"
        echo
        err "请依次检查："
        err "  1. 卡是否插在 CPU 直连的 x16 槽（单路机器上不能插挂 CPU2 的槽）"
        err "  2. 是否接了 48V/54V 辅助供电（不是普通 PCIe 12V）"
        err "  3. BIOS 是否开启 Above 4G Decoding"
        exit 1
    fi
    CARD_SHORT=${CARD#0000:}
    ok "找到 Gaudi2: $CARD"

    # PCIe 链路
    LNK=$(lspci -vv -s "$CARD_SHORT" 2>/dev/null | grep 'LnkSta:' | head -1)
    if echo "$LNK" | grep -q 'Width x0'; then
        die "PCIe 链路宽度 x0（无链路）: $LNK
        → 检查辅助供电与槽位（见上面提示）"
    fi
    ok "PCIe 链路: $(echo "$LNK" | sed 's/.*LnkSta:[[:space:]]*//')"

    info "预检通过"
}

# ----------------------------- 1. 基础软件栈 ---------------------------------
install_base() {
    step "安装 Intel Gaudi 基础软件栈"

    mkdir -p "$WORKDIR"

    # ---- 已安装？ ----
    if dpkg -l 2>/dev/null | grep -q "^ii  habanalabs-dkms *${PKG_VER}"; then
        ok "habanalabs ${PKG_VER} 已安装，跳过下载/安装"
    else
        info "下载官方安装器 ..."
        if ! curl -sSL --connect-timeout 30 -o "$WORKDIR/hli.sh" \
             "https://${HABANA_SERVER}/artifactory/gaudi-installer/${HABANA_VERSION}/habanalabs-installer.sh"; then
            warn "下载安装器失败，走手动路线"
        else
            chmod +x "$WORKDIR/hli.sh"
            info "运行官方安装器（--type base）..."
            # 官方脚本有 bug（_BREAK_ON_ERROR 不复位 / OpenMPI 检查误报），失败是常态
            "$WORKDIR/hli.sh" install --type base --force >/dev/null 2>&1 || \
                warn "官方安装器退出非 0（已知问题），继续走手动补装"
        fi
    fi

    # ---- 手动保证关键组件（幂等） ----
    info "配置 apt 源 ..."
    apt-get install -y -qq lsb-release >/dev/null 2>&1 || true
    cat > /etc/apt/sources.list.d/habanalabs_synapseai.list <<EOF
deb https://${HABANA_SERVER}/artifactory/debian $(. /etc/os-release; echo ${UBUNTU_CODENAME:-noble}) main
EOF
    curl -sSL --connect-timeout 30 "https://${HABANA_SERVER}/artifactory/api/gpg/key/public" \
        2>/dev/null | gpg --dearmor -o /usr/share/keyrings/habana.gpg 2>/dev/null || true

    # 给 vault 配代理需要时用（可选）
    apt-get update -qq 2>/dev/null || warn "apt update 有警告（可能网络问题）"

    info "安装/确认 habanalabs 关键包 ..."
    for p in habanalabs-firmware habanalabs-dkms habanalabs-firmware-tools habanalabs-firmware-odm; do
        if dpkg -l 2>/dev/null | grep -q "^ii  ${p} *${PKG_VER}"; then
            info "  $p 已就位"
        else
            if apt-get install -y -qq "${p}=${PKG_VER}" 2>/dev/null; then
                ok "  $p 已安装"
            else
                warn "  $p apt 安装失败，尝试直接下载 deb ..."
                install_deb_fallback "$p"
            fi
        fi
    done

    [ -e /lib/firmware/habanalabs/gaudi2/gaudi2-boot-fit.itb ] \
        || die "固件缺失（/lib/firmware/habanalabs/gaudi2/）"
    ok "固件就位"

    command -v hl-smi >/dev/null || die "hl-smi 缺失"
    ok "hl-smi 就位"
}

# apt 下载失败时（Habana deb 走 S3）逐个 curl
install_deb_fallback() {
    local pkg="$1"
    local url="https://${HABANA_SERVER}/artifactory/debian/$(. /etc/os-release; echo ${UBUNTU_CODENAME:-noble})/pool/main/h/${pkg}/${pkg}_${PKG_VER}_all.deb"
    local out="$WORKDIR/${pkg}.deb"
    # 先问 apt 要精确 URL 列表
    local urls
    urls=$(apt-get install --print-uris -y "${pkg}=${PKG_VER}" 2>/dev/null \
           | grep -oE "https://[^']+" | head -1)
    [ -n "$urls" ] && url="$urls"
    if curl -sSL --connect-timeout 60 -o "$out" "$url" && dpkg -i "$out" >/dev/null 2>&1; then
        ok "  $pkg 已通过 deb 安装"
    else
        warn "  $pkg 安装失败（可稍后手动安装）"
    fi
}

# ----------------------------- 2. 打补丁 -------------------------------------
apply_patches() {
    step "打驱动源码补丁"

    local S
    S=$(ls -d /usr/src/habanalabs-* 2>/dev/null | grep -vE '\.bak$|\.ORIG$' | head -1)
    [ -n "$S" ] || die "找不到 /usr/src/habanalabs-* 源码目录"
    info "源码目录: $S"

    local F="$S/drivers/accel/habanalabs/gaudi2/gaudi2_cn.c"
    local H="$S/drivers/accel/habanalabs/gaudi2/gaudi2_hbm_bringup.c"
    [ -f "$F" ] || die "找不到 $F"
    [ -f "$F.ORIG" ] || { cp "$F" "$F.ORIG"; info "已备份 -> $F.ORIG"; }

    # ---- 补丁① server_type ----
    if grep -q 'HL_SERVER_GAUDI2_HLS2; /\*PATCHED\*/' "$F"; then
        info "补丁①（server_type）已应用"
    else
        sed -i 's/hdev->asic_prop\.server_type = HL_SERVER_TYPE_UNKNOWN;/hdev->asic_prop.server_type = HL_SERVER_GAUDI2_HLS2; \/*PATCHED*\//' "$F"
        grep -q 'HL_SERVER_GAUDI2_HLS2; /\*PATCHED\*/' "$F" \
            && ok "补丁① 已应用（server_type: UNKNOWN → GAUDI2_HLS2）" \
            || warn "补丁① 未匹配（版本可能不同）"
    fi

    # ---- 补丁② 绕过 bad SerDes ----
    if grep -q 'PATCHED-ignore-bad-serdes' "$F"; then
        info "补丁②（绕过 bad SerDes）已应用"
    else
        sed -i 's/^\(\s*\)return -EFAULT;$/\1dev_warn(hdev->dev, "PATCHED-ignore-bad-serdes");/' "$F"
        grep -q 'PATCHED-ignore-bad-serdes' "$F" \
            && ok "补丁② 已应用（return -EFAULT → dev_warn）" \
            || warn "补丁② 未匹配"
    fi

    # ---- 补丁③ link_mask 不清零 ports_mask ----
    if grep -q 'PATCHED: FW link_mask=0' "$F"; then
        info "补丁③（保留 ports_mask）已应用"
    else
        python3 - "$F" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
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
    open(path, "w").write(src.replace(OLD, NEW, 1))
    print("  OK")
else:
    print("  NOT-MATCHED", file=sys.stderr)
    sys.exit(1)
PYEOF
        grep -q 'PATCHED: FW link_mask=0' "$F" \
            && ok "补丁③ 已应用（保留 ports_mask）" \
            || warn "补丁③ 未匹配（版本不同？请手动检查）"
    fi

    # ---- 补丁④ kernel 6.8 MIN/MAX 冲突 ----
    if [ -f "$H" ]; then
        if grep -q '^#define MIN(a, b)' "$H" 2>/dev/null; then
            [ -f "$H.ORIG" ] || cp "$H" "$H.ORIG"
            sed -i '/^#define MIN(a, b)/d; /^#define MAX(a, b)/d' "$H"
            ok "补丁④ 已应用（移除冲突的 MIN/MAX 宏）"
        else
            info "补丁④ 无需处理"
        fi
    fi
}

# ----------------------------- 3. 模块参数 -----------------------------------
setup_modparams() {
    step "配置模块参数"

    cat > /etc/modprobe.d/habanalabs-options.conf <<'EOF'
# Gaudi2 HL-225 必需参数
#   nic_ports_ext_mask=0 -> 所有 NIC 端口算作"内部"(scale-up)
#     不加这个 => 内部端口数 0 => SCAL 找不到 nic_scaleup => 设备获取失败
#   注意：不要加 card_type=0！它会把所有端口强制标成"外部"，抹掉 scale-up 端口
options habanalabs nic_ports_ext_mask=0
EOF
    ok "已写入 /etc/modprobe.d/habanalabs-options.conf"
    sed 's/^/     /' /etc/modprobe.d/habanalabs-options.conf

    if grep -q 'card_type' /etc/modprobe.d/habanalabs-options.conf; then
        warn "检测到 card_type 参数，建议删除（会破坏 scale-up 端口）"
    fi
}

# ----------------------------- 4. 编译加载驱动 -------------------------------
build_and_load() {
    step "编译并加载驱动"

    local S VER
    S=$(ls -d /usr/src/habanalabs-* 2>/dev/null | grep -vE '\.bak$|\.ORIG$' | head -1)
    VER=$(basename "$S" | sed 's/^habanalabs-//')
    info "DKMS 版本: $VER"

    # 清掉旧的 crash 报告，避免 dkms 报 "File exists"
    rm -f /var/crash/habanalabs-dkms.*.crash 2>/dev/null || true

    info "编译 ..."
    if ! dkms build "habanalabs/$VER" -k "$(uname -r)" --force >/dev/null 2>&1; then
        err "编译失败，错误摘要："
        grep -E 'error:' /var/lib/dkms/habanalabs/$VER/build/make.log 2>/dev/null | head -10 | sed 's/^/     /'
        die "DKMS 编译失败
        → 若报 'MIN/MAX redefined'：补丁④ 未应用
        → 若报 'format %x expects'： 补丁③ 的格式化符需用 %llx"
    fi
    ok "编译成功"

    if ! dkms install "habanalabs/$VER" -k "$(uname -r)" --force >/dev/null 2>&1; then
        warn "dkms install 返回非 0（可能因为 DKMS tree 已存在），继续"
    fi

    info "卸载旧模块 ..."
    rmmod habanalabs_ib habanalabs_en habanalabs_cn habanalabs 2>/dev/null || true
    sleep 3

    # 设备僵死时 rmmod 会失败
    if lsmod | grep -q '^habanalabs '; then
        die "模块无法卸载（设备僵死）→ 请先 sudo reboot 后重跑本脚本"
    fi

    info "按顺序加载（habanalabs 会触发固件下载，需等 50 秒）..."
    modprobe habanalabs_cn
    modprobe habanalabs_en
    modprobe habanalabs_ib
    modprobe habanalabs
    sleep 50

    ok "驱动已加载"
}

# ----------------------------- 5. 验证 RDMA 链路 -----------------------------
verify_rdma() {
    step "验证 RDMA 链路（最容易出问题的一环）"

    local fail=0

    # 1) aux 设备
    local naux
    naux=$(ls /sys/bus/auxiliary/devices/ 2>/dev/null | wc -l)
    if [ "$naux" -ge 3 ]; then
        ok "CN aux 设备: $naux 个"
        ls /sys/bus/auxiliary/devices/ | sed 's/^/     /'
    else
        err "CN aux 设备只有 $naux 个（期望 3）→ 补丁③ 或模块参数没生效"
        fail=1
    fi

    # 2) RDMA 设备
    if [ -d /sys/class/infiniband/hbl_0 ]; then
        ok "RDMA 设备: hbl_0"
    else
        err "没有 RDMA 设备（/sys/class/infiniband 为空）"
        fail=1
    fi

    # 3) ext_ports_mask 必须为 0
    local ext
    ext=$(cat /sys/class/infiniband/hbl_0/ext_ports_mask 2>/dev/null)
    if [ "$ext" = "0" ]; then
        ok "ext_ports_mask = 0（正确）"
    else
        err "ext_ports_mask = $ext（期望 0）→ 是否误加了 card_type=0？"
        fail=1
    fi

    # 4) NIC 网卡（异步创建且较慢，不是致命项）
    local nnic=0 i
    for i in $(seq 1 12); do
        nnic=$(ip -o link show 2>/dev/null | grep -cE 'ens2|eth[0-9]')
        [ "$nnic" -ge 1 ] && break
        sleep 5
    done
    if [ "$nnic" -ge 1 ]; then
        ok "Habana NIC 网卡: $nnic 个"
    else
        warn "未发现 Habana NIC 网卡（ens2*/eth*）"
        warn "  → 异步创建，较慢；不影响 HPU 计算"
    fi

    # 5) 设备节点
    if [ -e /dev/accel/accel0 ]; then ok "/dev/accel/accel0 存在"; else err "缺 /dev/accel/accel0"; fail=1; fi
    if [ -e /dev/infiniband/uverbs0 ]; then ok "/dev/infiniband/uverbs0 存在"; else warn "缺 uverbs0（若上面都过了可忽略）"; fi

    # 6) 内核日志
    echo "     ── 驱动日志 ──"
    dmesg 2>/dev/null | grep -E 'PATCHED|Found GAUDI2|IB device registered' | tail -3 | sed 's/^/     /'

    [ "$fail" -eq 0 ] || die "RDMA 链路验证未通过（见上面 ❌ 项）"
    ok "RDMA 链路完整 ✅"
}

# ----------------------------- 6. PyTorch 栈 ---------------------------------
install_pytorch() {
    step "安装匹配版本的 PyTorch 栈"

    # 检查是否已装
    if python3.12 -m pip list 2>/dev/null | grep -q "habana-torch-plugin *${HABANA_VERSION}"; then
        ok "PyTorch 栈已安装（habana-torch-plugin ${HABANA_VERSION}）"
        python3.12 -m pip list 2>/dev/null | grep -iE 'torch|habana' | sed 's/^/     /'
        ensure_thunk; ensure_ibverbs
        return
    fi

    local URL="https://${HABANA_SERVER}/artifactory/gaudi-pt-modules/${HABANA_VERSION}/${RELEASE_ID}/pytorch/ubuntu2404/${PT_MODULES_TGZ}"
    local TGZ="$WORKDIR/$PT_MODULES_TGZ"
    local DIR="$WORKDIR/ptmodules"

    info "下载 PyTorch 模块包（约 206 MB）..."
    [ -s "$TGZ" ] || curl -sSL --connect-timeout 60 -o "$TGZ" "$URL" \
        || die "下载失败: $URL"

    rm -rf "$DIR"; mkdir -p "$DIR"
    tar xzf "$TGZ" -C "$DIR"
    ok "已解包到 $DIR"

    # 环境
    export PIP_BREAK_SYSTEM_PACKAGES=1

    info "安装 torch 运行时依赖 ..."
    python3.12 -m pip install --break-system-packages -q \
        filelock typing-extensions sympy networkx jinja2 fsspec numpy==1.26.4 2>/dev/null \
        || warn "部分依赖安装失败（可能已有）"

    info "卸载旧版本 ..."
    python3.12 -m pip uninstall -y -q \
        habana-torch-plugin habana-torch-dataloader habana-gpu-migration \
        torch torchvision 2>/dev/null || true

    info "安装核心 wheels（--no-deps，避开需编译的包）..."
    ( cd "$DIR" && python3.12 -m pip install --break-system-packages --no-deps -q \
        torch-${TORCH_VER}a0+*.whl \
        habana_torch_plugin-${HABANA_VERSION}.${RELEASE_ID}-*.whl \
        habana_torch_dataloader-${HABANA_VERSION}.${RELEASE_ID}-*.whl \
        habana_gpu_migration-${HABANA_VERSION}.${RELEASE_ID}-*.whl \
        torchvision-*.whl ) || die "核心 wheels 安装失败"
    ok "核心 wheels 已安装"

    info "安装 habana-pyhlml ..."
    python3.12 -m pip install --break-system-packages -q \
        "habana-pyhlml==${HABANA_VERSION}.${RELEASE_ID}" 2>/dev/null \
        || warn "habana-pyhlml 安装失败（可能不影响基本功能）"

    ensure_thunk
    ensure_ibverbs

    ok "PyTorch 栈安装完成"
}

# 确保 libhl-thunk.so 存在（shared layer 必需）
ensure_thunk() {
    if [ -e /usr/lib/habanalabs/libhl-thunk.so ]; then
        info "libhl-thunk.so 已存在"
        return
    fi
    step "编译 libhl-thunk.so（shared layer 必需）"
    warn "未找到 libhl-thunk.so → 插件会报 'cannot initialize shared layer'"

    if [ ! -d /opt/habanalabs/src/hl-thunk ]; then
        err "缺少 /opt/habanalabs/src/hl-thunk（habanalabs-thunk 包未安装？）"
        return
    fi

    info "解掉依赖阻塞（pandoc）..."
    apt-get -f install -y -qq >/dev/null 2>&1 || true
    apt-get install -y -qq pandoc pandoc-data liblua5.4-0 >/dev/null 2>&1 || warn "pandoc 安装失败"

    info "编译 hl-thunk（tests 目标会失败，主库会生成）..."
    ( cd /opt/habanalabs/src/hl-thunk && \
      EXTRA_CMAKE_FLAGS="-DHLTESTS_LIB_MODE=ON -DHLTESTS_IB=ON" ./build.sh ) >/dev/null 2>&1 || true

    if [ -e /opt/habanalabs/src/hl-thunk/build/lib/libhl-thunk.so ]; then
        install -m 0755 /opt/habanalabs/src/hl-thunk/build/lib/libhl-thunk.so /usr/lib/habanalabs/
        [ -e /opt/habanalabs/src/hl-thunk/build/lib/libhl-thunk-err_injection.so ] && \
            install -m 0755 /opt/habanalabs/src/hl-thunk/build/lib/libhl-thunk-err_injection.so /usr/lib/habanalabs/
        ok "libhl-thunk.so 已编译并安装"
    else
        err "libhl-thunk.so 编译失败，请手动执行:
        cd /opt/habanalabs/src/hl-thunk && EXTRA_CMAKE_FLAGS='-DHLTESTS_LIB_MODE=ON -DHLTESTS_IB=ON' ./build.sh"
    fi
}

# 确保 Habana ibverbs provider + ld 配置正确
ensure_ibverbs() {
    local need=0
    [ -e /usr/lib/x86_64-linux-gnu/libibverbs/libhbl-rdmav34.so ] || need=1
    ls /etc/ld.so.conf.d/*.dpkg-new >/dev/null 2>&1 && need=1
    [ "$need" -eq 0 ] && return

    step "补装 ibverbs provider 并修正 ld 配置"
    if [ -e /opt/habanalabs/rdma-core/src/build/lib/libhbl-rdmav34.so ]; then
        install -m 0755 /opt/habanalabs/rdma-core/src/build/lib/libhbl-rdmav34.so \
            /usr/lib/x86_64-linux-gnu/libibverbs/ 2>/dev/null && ok "ibverbs provider 已安装"
    else
        warn "找不到 libhbl-rdmav34.so（rdma-core 可能未编译）"
    fi
    for f in /etc/ld.so.conf.d/*.dpkg-new; do
        [ -e "$f" ] && mv -f "$f" "${f%.dpkg-new}" && info "已修正 $(basename "${f%.dpkg-new}")"
    done
    ldconfig
    ok "ldconfig 已刷新"
}

# ----------------------------- 7. 运行环境 -----------------------------------
setup_runtime_env() {
    step "配置运行环境"

    mkdir -p /var/log/habana_logs
    chmod 777 /var/log/habana_logs
    ok "日志目录 /var/log/habana_logs 就绪"

    # 便捷命令
    cat > /usr/local/bin/hpu-run <<'EOF'
#!/bin/bash
# Habana HPU 运行包装器
# 用法: hpu-run python3 your_script.py
source /etc/profile.d/habanalabs.sh 2>/dev/null
export LD_PRELOAD=/lib/x86_64-linux-gnu/libtcmalloc.so.4
exec "$@"
EOF
    chmod +x /usr/local/bin/hpu-run
    ok "已安装便捷命令: hpu-run"

    # 校验关键环境变量（来自 profile.d）
    local missing=0
    for v in GC_KERNEL_PATH HABANA_PLUGINS_LIB_PATH HABANA_SCAL_BIN_PATH; do
        if grep -q "export $v=" /etc/profile.d/habanalabs.sh 2>/dev/null; then
            info "$v = $(grep "export $v=" /etc/profile.d/habanalabs.sh | head -1 | cut -d= -f2-)"
        else
            err "$v 未在 /etc/profile.d/habanalabs.sh 中定义"; missing=1
        fi
    done

    if [ -e /usr/lib/habanalabs/libtpc_kernels.so ]; then
        ok "libtpc_kernels.so 存在（$(du -h /usr/lib/habanalabs/libtpc_kernels.so | cut -f1)）"
    else
        die "缺 libtpc_kernels.so！图编译一定失败"
    fi

    [ "$missing" -eq 0 ] || die "环境变量脚本不完整"

    warn "⚠️  跑任何 HPU 程序前必须 source /etc/profile.d/habanalabs.sh"
    warn "   最简单的方式：用 hpu-run 或 bash -lc"
}

# ----------------------------- 8. 端到端验证 ---------------------------------
final_verify() {
    step "端到端验证"

    # hl-smi
    if command -v hl-smi >/dev/null; then
        echo "     ── hl-smi ──"
        hl-smi 2>/dev/null | sed -n '1,13p' | sed 's/^/     /'
    fi

    info "运行 HPU 计算测试（首次图编译较慢，耐心等）..."
    if bash -lc '
        source /etc/profile.d/habanalabs.sh
        export LD_PRELOAD=/lib/x86_64-linux-gnu/libtcmalloc.so.4
        python3 - <<"PY"
import torch
import habana_frameworks.torch.core as htcore
print("  device_name :", torch.hpu.get_device_name(0))
a = torch.randn(2048, 2048, device="hpu")
b = torch.randn(2048, 2048, device="hpu")
c = a @ b
htcore.mark_step()
print("  matmul      :", float(c.sum().cpu()))
net = torch.nn.Sequential(torch.nn.Linear(512, 1024), torch.nn.ReLU(),
                          torch.nn.Linear(1024, 10)).to("hpu")
loss = net(torch.randn(32, 512, device="hpu")).sum()
loss.backward()
htcore.mark_step()
print("  fwd+bwd     :", float(loss.detach().cpu()))
print("  RESULT: HPU WORKS")
PY
    '; then
        echo
        echo "═══════════════════════════════════════════════════════════════"
        echo -e "  ${C_G}🎉 部署成功！HPU 计算已验证可用${C_N}"
        echo "═══════════════════════════════════════════════════════════════"
        echo
        echo "  日常使用："
        echo "    hpu-run python3 your_script.py"
        echo "    或  sudo bash -lc 'source /etc/profile.d/habanalabs.sh; python3 your_script.py'"
        echo
    else
        echo
        err "HPU 测试失败。请检查："
        err "  1. 是否 source 了 /etc/profile.d/habanalabs.sh"
        err "  2. 日志: cat /var/log/habana_logs/synapse_runtime.log"
        err "  3. 若报 synGraphCompile 失败 → 环境变量没加载"
        echo
        exit 1
    fi
}

# ----------------------------- 主流程 ----------------------------------------
main() {
    banner
    preflight

    [ "$DO_BASE"    -eq 1 ] && install_base
    [ "$DO_PATCH"   -eq 1 ] && apply_patches

    if [ "$DO_BASE" -eq 1 ] || [ "$DO_PATCH" -eq 1 ]; then
        setup_modparams
        build_and_load
    fi

    verify_rdma

    [ "$DO_PYTORCH" -eq 1 ] && install_pytorch
    setup_runtime_env

    [ "$DO_VERIFY" -eq 1 ] && final_verify

    echo
    echo "完整日志: $LOG"
}

main "$@"
