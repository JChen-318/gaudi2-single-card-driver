# gaudi2-single-card-driver

> **使用 NVIDIA OAM 转接卡将 Intel Gaudi2 转接到 PCIe,并在 Ubuntu 下正常驱动和使用的完整指南。**

在非 Intel 认证平台上,用 **Gaudi2 OAM 模组 + OAM→PCIe 转接卡** 跑通 HPU 计算与训练。
包含一键部署脚本、驱动补丁、硬件诊断、以及**内核 panic 的完整根因分析**。

---

## ✅ 已验证结果

```
Gaudi 软件       : 1.24.1-482
Gaudi PyTorch    : 2.11.0a0+git009b5f6
habana-torch-plugin : 1.24.1.482
Python           : 3.12

HPU 可用         : True
设备名           : GAUDI2
显存             : 101.6 GB (96GB HBM2e)

matmul 4096x4096 : OK   (0.7s)
relu / softmax   : OK
前向 + 反向传播   : OK   (0.2s)

重启后依然正常 ✅
```

---

## 🚀 快速开始

```bash
git clone https://github.com/JChen-318/gaudi2-single-card-driver.git
cd gaudi2-single-card-driver

sudo ./scripts/install-gaudi2.sh
```

脚本会依次完成:环境预检 → 配置 `iommu=pt` → 装 Gaudi 1.24.1 → 打驱动补丁 →
DKMS 编译 → 模块参数 → 装 PyTorch 2.11 → 环境配置 → 安全网 → 端到端验证。

### 常用变体

```bash
sudo ./scripts/install-gaudi2.sh --skip-pytorch   # 只装驱动
sudo ./scripts/install-gaudi2.sh --verify-only    # 只验证(不改动系统)
sudo ./scripts/install-gaudi2.sh --check-iommu    # 只检查/配置 iommu=pt
```

### 日常使用

```bash
/usr/local/bin/gaudi-check            # 一键健康检查
hpu-run python3 your_script.py        # 在正确环境下跑程序
```

---

## 🎯 完整方案:5 项修复

| # | 修复 | 作用 |
|---|---|---|
| ① | 驱动补丁 `server_type = HL_SERVER_GAUDI2_HLS2` | 绕过 `UNKNOWN` 服务器类型 |
| ② | 驱动补丁 忽略 `bad SerDes type 0xFFFF` | 绕过 OAM 转接卡的枚举失败 |
| ③ | 驱动补丁 固件 `link_mask=0` 时不清零 `ports_mask` | 让 CN 初始化 + RDMA 可用 |
| ④ | **内核参数 `iommu=pt`** ⭐ | **★ 核心:修复 1.24.1 的 host-resident 页表 bug(消除内核 panic)** |
| ⑤ | 模块参数 `nic_ports_ext_mask=0` | 让 SCAL 建起 scale-up 集群 |

> ⚠️ **第 ④ 项是必须的。** 不加 `iommu=pt`,Gaudi 1.24.1 驱动会 **100% 内核 panic**。
> 详见 [`完整解决方案.md`](./完整解决方案.md)。

---

## 🔬 内核 panic 根因(完整分析)

升级到 1.24.1 后,只要真正获取 HPU 设备就会 **内核 panic**(页表被踩坏),复现 7 次。

### 根因

**1.24.1 给 Gaudi2 的 PMMU 启用了 "host-resident 页表"**
(1.18.0 没有这个机制):

```c
/* gaudi2/gaudi2.c */
prop->dmmu.host_resident = 0;
prop->pmmu.host_resident = 1;      /* ← 1.24.1 新加:PMMU 页表放到【主机内存】 */
```

驱动把 `dma_alloc_coherent()` 返回的 **DMA/IOVA 地址当作物理地址**存进页池:

```c
/* common/mmu/mmu.c :: hl_mmu_hr_init() */
rc = gen_pool_add_virt(pool, virt_addr, (phys_addr_t) dma_addr, pool_chunk_size, -1);
//                                         ^^^^^^^^^^^^^^^^^^^^^ ← bug
```

在 **IOMMU Translated(`DMA-FQ`)域**下 `dma_addr` 是 IOVA ≠ 物理地址,
于是地址换算 `pgt->virt_addr + (phys_pte_addr & 0xFFF)` 偏到隔壁页:

```c
/* common/mmu/mmu.c :: hl_mmu_hr_write_pte() */
*((u64 *) (uintptr_t) virt_addr) = val;   // ← CPU 直接解引用写 PTE
```

**CPU 把 PTE 数据写进了别人的页表页 → `Corrupted page table` → Kernel panic。**

### 为什么 `iommu=pt` 能修好

`iommu=pt` 让 `dma_addr == 物理地址`,两者页内偏移必然一致 → 推导成立 →
**既不崩,映射也成功**。

### 排除过程(证据链)

| 假设 | 实验 | 结果 |
|---|---|---|
| 坏 DMA 越界 | 查 IOMMU 域类型 | 域是 `DMA-FQ`(转换域)→ 越界必报 DMAR fault,**零 DMAR fault** → 排除 |
| CN/NIC 子系统 | 黑名单 + 补丁跳过整个 `hl_cn_init` | 照样 panic → 排除 |
| `libhl-thunk.so` 版本错配 | 查 `CompileError.log` | 其实是成功日志 → 排除 |
| torch 装错 | 重装 Habana fork | 仍 panic → 排除 |
| 内存硬件故障 | EDAC / MCE | 无报错 → 排除 |
| **Host-Resident 页表** | **`pmmu.host_resident = 0`** | **panic 完全消失** → **锁定** |

---

## 🔧 硬件层关键知识(★ 容易踩坑)

### 1. PCIe 不识别先拧螺丝

> **`LnkSta: Width x0` 最常见的根因是 OAM 卡螺丝没拧紧。**

OAM 模组靠**螺丝压紧**保证 OAM 连接器与转接卡之间的信号完整性。
螺丝松了 → 接触不良 → PCIe 链路训练失败 → 完全不识别。

### 2. PCB 上的两个 LED

```
   ●━━━  横着的 → 检测【电源】是否正常   (黄色 = 供电有问题)
   ┃     竖着的 → 检测【是否被系统识别】  (黄色 = 没安装到位)
```

> **口诀:横着看电源,竖着看识别;哪个是黄的,就往哪个方向查。**
> **黄色 = 没安装到位。**

### 3. CPLD `0x10` 是正常的

Intel 的 Gaudi 1.18.0 支持矩阵明确列出 **HL-225H/C 的正常 CPLD 版本就是 `0x10`**。

**不要尝试刷 CPLD** —— `hl-fw-loader` 的 CPLD 选项标注 "For internal use ONLY / Deprecated",
而 `0x10` 本来就是正常的。

详见 [`硬件安装与LED诊断.md`](./硬件安装与LED诊断.md)。

---

## 🔍 检测 `SerDes type = 0xFFFF` 的由来

卡通过 OAM→PCIe 转接卡连接时,驱动会报:

```
habanalabs: bad SerDes type 65535          # = UNKNOWN_SERDES_TYPE (0xFFFF)
habanalabs: Failed to get cpucp info
habanalabs: Failed to initialize accel0. Device is NOT usable!
```

**这是 OAM 转接卡的物理配置不在 Intel 的合法枚举列表里导致的**,与驱动/固件版本无关
(已用 1.18.0 与 1.24.1 两版驱动**双重验证**)。

**只能靠驱动补丁绕过**(补丁①②)。

---

## 📁 文档

| 文件 | 内容 |
|---|---|
| [`完整解决方案.md`](./完整解决方案.md) | 🥇 **最终方案** —— 5 项修复 + panic 根因分析 + 证据链 + 回滚 |
| [`硬件安装与LED诊断.md`](./硬件安装与LED诊断.md) | 🆕 **硬件层** —— LED 含义、螺丝、PCIe 排查流程 |
| [`1.24.1升级与panic排查记录.md`](./1.24.1升级与panic排查记录.md) | 升级过程 + 7 次 panic 排查(netconsole 黑匣子方案) |
| [`HL225-排查全记录.md`](./HL225-排查全记录.md) | 第一轮:从"完全识别不到"到"HPU 能算" |
| [`部署手册.md`](./部署手册.md) | 操作手册 + 排错速查表 |

## 📁 脚本(`scripts/`)

| 文件 | 用途 |
|---|---|
| `install-gaudi2.sh` | ⭐ 一键部署(Gaudi 1.24.1) |
| `install-gaudi2-1.18.0-legacy.sh` | 老版本(1.18.0),回滚参考 |
| `patch-gaudi.py` | 版本无关的补丁脚本(幂等) |
| `patch-hr-pgt.py` / `patch-nic-skip.py` | 诊断用补丁(HR 页表 / NIC) |
| `netconsole-listen.py` | **内核日志黑匣子接收端** |
| `netconsole-panic证据.log` | ★ 7 次 panic 的完整现场日志 |
| `gaudi-check.sh` | 健康检查 |

---

## 🛠️ 调试工具(强烈推荐)

### netconsole —— 内核日志黑匣子

内核硬锁死时 `journald` 一行都写不出来,panic 现场会全部丢失:

```bash
# 接收端
python3 scripts/netconsole-listen.py

# 服务器端
sudo modprobe netconsole netconsole=6666@<本机IP>/<网卡>,6666@<接收端IP>/<接收端MAC>
echo 8 | sudo tee /proc/sys/kernel/printk     # ★ 必须提到 8,否则收不到驱动日志
```

### 内核自恢复看门狗 —— 免物理断电

```bash
sudo bash -c '
  echo 1  > /proc/sys/kernel/nmi_watchdog
  echo 1  > /proc/sys/kernel/hardlockup_panic
  echo 1  > /proc/sys/kernel/panic_on_oops
  echo 20 > /proc/sys/kernel/panic          # panic 后 20 秒自动重启
'
```

**这两个工具是本次排查能进行下去的根本** —— 7 次 panic 全部自动恢复,现场全部抓到。

---

## ⚠️ 已知限制

1. **平台不在 Intel 官方支持列表**(测试平台:Haswell-EP 2014 vs 官方要求 Xeon Scalable 4/5 代)
2. **PCIe 带宽可能只有官方要求的 1/4**(测试平台 Gen3 x8 vs 官方 Gen4 x16)
3. **硬件 `SerDes type` 未知** —— 这是 OAM 转接卡的物理配置决定的,只能靠补丁绕过
4. 补丁在 `habanalabs-dkms` 升级后会丢失 —— 脚本已 `apt-mark hold` 防止意外升级
5. `ens2*` 网卡数量在 1.24.1 下为 0(1.18.0 为 24 个)—— 单卡使用不受影响

---

## 🔍 关键踩坑提醒

| 坑 | 一句话 |
|---|---|
| **PCIe 不识别** | **先拧紧 OAM 卡螺丝**,再看竖着的 LED |
| **供电** | 要 **48V/54V**,不是普通 PCIe 12V |
| **槽位** | 必须 CPU 直连 x16(单路机器上挂 CPU2 的槽是死的) |
| **`iommu=pt`** | **不加必 panic**(1.24.1 的 HR 页表 bug) |
| **DKMS** | 补丁要改 `/usr/src/`,**且必须先 `dkms build --force`**(否则产出 0 字节模块) |
| **模块参数** | `nic_ports_ext_mask=0` 必需,**`card_type=0` 千万别加** |
| **PyTorch 安装顺序** | 本地 torch wheel **必须最后装**,否则 Habana fork 被上游 CPU 版覆盖 |
| **环境变量** | 跑程序前**必须** `source /etc/profile.d/habanalabs.sh` |
| **`.ko.zst` 是压缩的** | 验证补丁用 `zstd -dc <file> \| strings \| grep PATCHED` |
| **CPLD `0x10`** | 是**正常值**,不要去刷 |

---

## 🤝 贡献

欢迎提交不同 OAM 转接卡 / 主板 / 驱动版本的兼容性报告。

**特别欢迎:**
- 其他 OAM 转接卡的兼容性验证
- 其他驱动版本(1.22 / 1.23)的补丁适配
- Intel 对该 bug 的官方回应

---

## ⚖️ 免责声明

本项目为**非官方**社区方案,针对特定硬件组合(OAM 转接卡 + 老平台)的踩坑总结。

- 修改内核驱动源码、绕过厂商校验**属于非官方做法**,可能带来稳定性风险
- 请自行评估并承担风险,**生产环境使用前请充分压测**
- 所有涉及 Intel Gaudi / Habana 的商标归 Intel Corporation 所有
- 本项目与 Intel Corporation 无任何关联
