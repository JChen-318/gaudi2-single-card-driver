<div align="center">

# Gaudi2 单卡驱动实战指南

**让 Intel Gaudi2 OAM 模组在非认证 PCIe 平台稳定运行**

[![Gaudi](https://img.shields.io/badge/Intel%20Gaudi-2-0071C5?style=flat-square&logo=intel&logoColor=white)](https://habana.ai/)
[![Software](https://img.shields.io/badge/Gaudi%20Software-1.24.1-2F7DE1?style=flat-square)](https://docs.habana.ai/)
[![PyTorch](https://img.shields.io/badge/PyTorch-2.11-EE4C2C?style=flat-square&logo=pytorch&logoColor=white)](https://pytorch.org/)
[![Platform](https://img.shields.io/badge/Platform-Ubuntu-E95420?style=flat-square&logo=ubuntu&logoColor=white)](#环境要求)
[![License](https://img.shields.io/badge/Use%20at%20your%20own%20risk-lightgrey?style=flat-square)](#免责声明)

OAM → PCIe 转接 · 一键部署 · 驱动补丁 · 硬件诊断 · Kernel Panic 根因分析

[快速开始](#快速开始) · [方案概览](#方案概览) · [硬件诊断](#硬件诊断) · [文档导航](#文档导航) · [已知限制](#已知限制)

</div>

> [!WARNING]
> **Gaudi 1.24.1 必须启用 `iommu=pt`。** 在已验证的平台上，缺少该参数会在真正获取 HPU 设备时触发内核 panic。请先阅读[风险说明](#开始前必读)，不要直接在生产环境执行。

## 这个项目解决什么问题？

在非 Intel 认证平台上，通过 **Gaudi2 OAM 模组 + OAM → PCIe 转接卡** 跑通 HPU 计算与训练。本仓库将硬件安装、驱动适配、PyTorch 环境、故障定位与恢复方案整理为一条可复现的部署路径。

| 你现在的情况 | 建议入口 |
|---|---|
| 准备第一次安装 | [快速开始](#快速开始) → [`部署手册.md`](./部署手册.md) |
| PCIe 完全识别不到设备 | [硬件诊断](#硬件诊断) → [`硬件安装与LED诊断.md`](./硬件安装与LED诊断.md) |
| 遇到 `bad SerDes type 65535` | [SerDes 说明](#serdes-type--0xffff) → [`完整解决方案.md`](./完整解决方案.md) |
| 获取 HPU 时内核崩溃 | [Kernel Panic 根因](#kernel-panic-根因) → [`1.24.1升级与panic排查记录.md`](./1.24.1升级与panic排查记录.md) |
| 已安装，只想检查状态 | 运行 `/usr/local/bin/gaudi-check` |

## 已验证配置

| 项目 | 验证结果 |
|---|---|
| Gaudi 软件栈 | `1.24.1-482` |
| Gaudi PyTorch | `2.11.0a0+git009b5f6` |
| Habana Torch Plugin | `1.24.1.482` |
| Python | `3.12` |
| HPU | **可用** · `GAUDI2` |
| HBM | **101.6 GB**（96 GB HBM2e） |
| 基础算子 | `matmul 4096 × 4096`、ReLU、Softmax 均通过 |
| 训练链路 | 前向 + 反向传播通过 |
| 重启验证 | **通过** |

## 快速开始

### 环境要求

- Ubuntu Linux
- CPU 直连的 PCIe x16 插槽
- 48 V / 54 V 独立供电
- Gaudi2 OAM 模组与兼容的 OAM → PCIe 转接卡
- 可使用 `sudo` 的账户

> [!IMPORTANT]
> 安装过程会修改内核启动参数、安装 DKMS 模块并锁定部分软件包。请先确保系统具备可用的远程控制或物理恢复手段。

### 一键安装

```bash
git clone https://github.com/JChen-318/gaudi2-single-card-driver.git
cd gaudi2-single-card-driver

sudo ./scripts/install-gaudi2.sh
```

安装脚本将依次完成：

```text
环境预检 → 配置 iommu=pt → 安装 Gaudi 1.24.1 → 应用驱动补丁
        → DKMS 编译 → 写入模块参数 → 安装 PyTorch → 端到端验证
```

### 按需执行

```bash
# 只安装驱动，不安装 PyTorch
sudo ./scripts/install-gaudi2.sh --skip-pytorch

# 只验证当前系统，不修改配置
sudo ./scripts/install-gaudi2.sh --verify-only

# 只检查并配置 iommu=pt
sudo ./scripts/install-gaudi2.sh --check-iommu
```

### 日常使用

```bash
# 一键健康检查
/usr/local/bin/gaudi-check

# 在正确的 Habana 环境中运行程序
hpu-run python3 your_script.py
```

## 方案概览

完整方案由 5 项修复组成。其中第 4 项是解决 1.24.1 内核 panic 的关键。

| # | 修复 | 解决的问题 | 必要性 |
|:---:|---|---|:---:|
| 1 | 设置 `server_type = HL_SERVER_GAUDI2_HLS2` | 绕过 `UNKNOWN` 服务器类型 | 必需 |
| 2 | 忽略 `bad SerDes type 0xFFFF` | 绕过转接卡枚举失败 | 必需 |
| 3 | `link_mask=0` 时保留 `ports_mask` | 让 CN 初始化与 RDMA 可用 | 必需 |
| 4 | 设置内核参数 `iommu=pt` | 修复 host-resident 页表地址错误，消除 panic | **核心** |
| 5 | 设置 `nic_ports_ext_mask=0` | 让 SCAL 建立 scale-up 集群 | 必需 |

完整补丁逻辑、验证方法与回滚步骤见 [`完整解决方案.md`](./完整解决方案.md)。

## 开始前必读

> [!CAUTION]
> 本方案会修改内核驱动源码并绕过厂商的部分平台校验，属于非官方适配方案。建议先在测试机验证，并提前准备 netconsole 与自动重启看门狗。

| 高风险项 | 必须确认 |
|---|---|
| `iommu=pt` | Gaudi 1.24.1 在本项目目标平台上的必要参数 |
| 供电 | 必须使用 **48 V / 54 V**，不能使用普通 PCIe 12 V |
| 插槽 | 必须连接到当前 CPU 可用的直连插槽 |
| DKMS | 补丁应修改 `/usr/src/`，并执行 `dkms build --force` |
| 模块参数 | 需要 `nic_ports_ext_mask=0`；**不要添加 `card_type=0`** |
| PyTorch | Habana 的本地 wheel 最后安装，避免被上游 CPU 版覆盖 |

## Kernel Panic 根因

Gaudi 1.24.1 为 Gaudi2 的 PMMU 启用了 **host-resident 页表**。在 IOMMU Translated（`DMA-FQ`）域下，驱动错误地把 `dma_alloc_coherent()` 返回的 DMA/IOVA 地址当作物理地址写入页池，最终可能把 PTE 写进其他页表页，触发 `Corrupted page table` 与内核 panic。

`iommu=pt` 使 `dma_addr` 与物理地址保持一致，让驱动原有的地址换算重新成立。

<details>
<summary><strong>展开查看关键代码与推导</strong></summary>

1.24.1 中 Gaudi2 PMMU 的配置：

```c
/* gaudi2/gaudi2.c */
prop->dmmu.host_resident = 0;
prop->pmmu.host_resident = 1;
```

驱动将 DMA 地址作为物理地址加入页池：

```c
/* common/mmu/mmu.c :: hl_mmu_hr_init() */
rc = gen_pool_add_virt(pool, virt_addr, (phys_addr_t) dma_addr,
                       pool_chunk_size, -1);
```

随后 CPU 直接解引用换算后的地址写入 PTE：

```c
/* common/mmu/mmu.c :: hl_mmu_hr_write_pte() */
*((u64 *) (uintptr_t) virt_addr) = val;
```

在转换域中 `dma_addr` 是 IOVA，不等于物理地址，页内偏移可能指向错误页面。`iommu=pt` 让二者一致，从而消除该错误。

</details>

<details>
<summary><strong>展开查看排除过程与证据链</strong></summary>

| 假设 | 实验 | 结果 |
|---|---|---|
| 坏 DMA 越界 | 检查 IOMMU 域类型 | `DMA-FQ` 转换域下无 DMAR fault，排除 |
| CN/NIC 子系统 | 黑名单并跳过整个 `hl_cn_init` | 仍然 panic，排除 |
| `libhl-thunk.so` 版本错配 | 检查 `CompileError.log` | 实际为成功日志，排除 |
| PyTorch 安装错误 | 重装 Habana fork | 仍然 panic，排除 |
| 内存硬件故障 | 检查 EDAC / MCE | 无报错，排除 |
| Host-resident 页表 | 设置 `pmmu.host_resident = 0` | panic 消失，锁定根因 |

</details>

完整复现与 7 次 panic 的现场记录见 [`1.24.1升级与panic排查记录.md`](./1.24.1升级与panic排查记录.md)。

## 硬件诊断

### PCIe 不识别：先检查安装压力

> [!TIP]
> 当 `LnkSta: Width x0` 时，先确认 OAM 卡的固定螺丝是否均匀拧紧。OAM 模组依靠螺丝压力保证连接器信号完整性；接触不良会直接导致 PCIe 链路训练失败。

### PCB LED 速查

```text
●━━━  横向 LED：电源状态；黄色表示供电异常
┃     纵向 LED：系统识别；黄色表示安装或识别异常
```

**记忆口诀：横向看电源，纵向看识别；哪个变黄，就从哪个方向排查。**

### CPLD `0x10` 是正常值

Intel 的 Gaudi 1.18.0 支持矩阵中，HL-225H/C 的正常 CPLD 版本即为 `0x10`。不要尝试刷写 CPLD：`hl-fw-loader` 的 CPLD 选项标注为仅限内部使用并已弃用。

更多硬件排查步骤见 [`硬件安装与LED诊断.md`](./硬件安装与LED诊断.md)。

## SerDes type = `0xFFFF`

通过 OAM → PCIe 转接卡连接时，驱动可能输出：

```text
habanalabs: bad SerDes type 65535
habanalabs: Failed to get cpucp info
habanalabs: Failed to initialize accel0. Device is NOT usable!
```

这是转接卡物理配置不在 Intel 合法枚举列表中导致的。该现象已在 1.18.0 与 1.24.1 两版驱动上复现，与单一驱动或固件版本无关，需要通过方案中的第 1、2 项驱动补丁绕过。

## 文档导航

| 文档 | 适合什么时候看 | 内容 |
|---|---|---|
| [`完整解决方案.md`](./完整解决方案.md) | **优先阅读** | 5 项修复、panic 根因、证据链与回滚 |
| [`部署手册.md`](./部署手册.md) | 准备安装或排错 | 完整操作流程与故障速查 |
| [`硬件安装与LED诊断.md`](./硬件安装与LED诊断.md) | 设备无法枚举 | LED、螺丝、供电与 PCIe 排查 |
| [`1.24.1升级与panic排查记录.md`](./1.24.1升级与panic排查记录.md) | 调查内核崩溃 | 升级过程、7 次 panic 与 netconsole 证据 |
| [`HL225-排查全记录.md`](./HL225-排查全记录.md) | 需要完整背景 | 从完全无法识别到 HPU 可计算的第一轮记录 |

## 工具与脚本

| 文件 | 用途 |
|---|---|
| [`scripts/install-gaudi2.sh`](./scripts/install-gaudi2.sh) | **推荐入口**：一键部署 Gaudi 1.24.1 |
| [`scripts/install-gaudi2-1.18.0-legacy.sh`](./scripts/install-gaudi2-1.18.0-legacy.sh) | 1.18.0 旧版与回滚参考 |
| [`scripts/patch-gaudi.py`](./scripts/patch-gaudi.py) | 版本无关、可重复执行的补丁脚本 |
| [`scripts/patch-hr-pgt.py`](./scripts/patch-hr-pgt.py) | host-resident 页表诊断补丁 |
| [`scripts/patch-nic-skip.py`](./scripts/patch-nic-skip.py) | NIC 初始化诊断补丁 |
| [`scripts/netconsole-listen.py`](./scripts/netconsole-listen.py) | 内核日志黑匣子接收端 |
| [`scripts/netconsole-panic证据.log`](./scripts/netconsole-panic证据.log) | 7 次 panic 的完整现场日志 |

<details>
<summary><strong>调试工具：netconsole 与自动恢复看门狗</strong></summary>

内核硬锁死时，`journald` 可能无法落盘。可使用 netconsole 在另一台机器接收日志：

```bash
# 接收端
python3 scripts/netconsole-listen.py

# 服务器端
sudo modprobe netconsole netconsole=6666@<本机IP>/<网卡>,6666@<接收端IP>/<接收端MAC>
echo 8 | sudo tee /proc/sys/kernel/printk
```

配置 panic 后自动重启，避免每次都需要物理断电：

```bash
sudo bash -c '
  echo 1  > /proc/sys/kernel/nmi_watchdog
  echo 1  > /proc/sys/kernel/hardlockup_panic
  echo 1  > /proc/sys/kernel/panic_on_oops
  echo 20 > /proc/sys/kernel/panic
'
```

</details>

## 已知限制

1. 测试平台不在 Intel 官方支持列表中（Haswell-EP 2014；官方要求 Xeon Scalable 第 4 / 5 代）。
2. 测试平台为 Gen3 x8，PCIe 带宽可能只有官方 Gen4 x16 要求的约四分之一。
3. OAM 转接卡的物理配置导致 `SerDes type` 未知，只能通过补丁绕过。
4. `habanalabs-dkms` 升级后补丁会丢失；安装脚本已使用 `apt-mark hold` 防止意外升级。
5. 1.24.1 下 `ens2*` 网卡数量为 0（1.18.0 为 24 个），不影响单卡计算场景。

## 故障速查

| 现象 | 首要检查项 |
|---|---|
| PCIe 完全不识别 | 拧紧 OAM 卡螺丝，检查纵向 LED 与 CPU 直连插槽 |
| 供电异常 | 确认使用 48 V / 54 V 独立供电，而不是 PCIe 12 V |
| 获取设备时 panic | 确认启动参数中存在 `iommu=pt` |
| DKMS 生成 0 字节模块 | 确认补丁位于 `/usr/src/`，执行 `dkms build --force` |
| SCAL 无法建立集群 | 确认 `nic_ports_ext_mask=0`，且没有 `card_type=0` |
| PyTorch 识别不到 HPU | 最后安装 Habana wheel，并加载 `/etc/profile.d/habanalabs.sh` |
| 无法验证压缩模块 | 使用 `zstd -dc <file> \| strings \| grep PATCHED` |
| CPLD 显示 `0x10` | 正常，无需刷写 |

## 参与贡献

欢迎提交不同 OAM 转接卡、主板和驱动版本的兼容性结果。为了让报告更容易复现，建议在 [Issues](https://github.com/JChen-318/gaudi2-single-card-driver/issues) 中附上：

- CPU、主板、PCIe 插槽与转接卡型号
- Ubuntu、Kernel 与 Gaudi 软件栈版本
- `lspci -vv`、`hl-smi` 和 `dmesg` 中的关键输出
- 已应用的补丁与内核参数

特别欢迎 1.22 / 1.23 驱动适配结果，以及 Intel 对 host-resident 页表问题的官方回应。

## 免责声明

本项目是面向特定硬件组合（OAM 转接卡 + 非认证平台）的**非官方社区方案**。

- 修改内核驱动源码、绕过厂商校验可能带来稳定性与数据安全风险。
- 使用者应自行评估风险，并在生产环境使用前完成充分压测。
- Intel Gaudi 与 Habana 的相关商标归 Intel Corporation 所有。
- 本项目与 Intel Corporation 无任何关联。

---

<div align="center">

如果这份排查记录帮你节省了时间，欢迎点亮 ⭐，也欢迎分享你的硬件兼容性结果。

</div>
