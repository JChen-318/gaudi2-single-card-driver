# gaudi2-single-card-driver

> **使用 NVIDIA OAM 转接卡将 Intel Gaudi2 转接到 PCIe，并在 Ubuntu 下正常驱动和使用的完整指南。**

在非 Intel 认证平台上，用单张 **Gaudi2（OAM 模组 + OAM→PCIe 转接卡）** 跑通
PyTorch / HPU 计算。包含一键部署脚本、驱动补丁、完整排查记录。

---

## ✅ 验证结果

```
device_name : GAUDI2
matmul      : -33622.9921875          # 4096x4096 矩阵乘
fwd+bwd     : -4.757617950439453      # 前向 + 反向传播
RESULT: HPU WORKS
```

**在 Haswell-EP（2014 年）老平台上跑通了 Gaudi2 的神经网络训练。**

---

## 🎯 这个项目解决什么问题

Gaudi2 OAM 模组通过转接卡接到 PCIe 后，**官方驱动无法直接使用**。原因是
这块卡向所有版本的驱动报告：

```
habanalabs: bad SerDes type 65535          # = UNKNOWN_SERDES_TYPE (0xFFFF)
habanalabs: Failed to get cpucp info
habanalabs: failed to initialize the H/W
habanalabs: Failed to initialize accel0. Device is NOT usable!
```

`SerDes type = 0xFFFF` 是 **硬件 CPLD strapping 采样**得出的值（已用 1.18.0 与
1.24.2 两版驱动**双重验证**，与驱动/固件版本无关），OAM 模组的物理配置不在
Intel 的合法枚举列表里。

**本项目通过 3 处驱动源码补丁 + 1 个模块参数 + 正确的环境配置，完整绕过了这 8 层障碍。**

---

## 🧩 8 层障碍与解法

| # | 层级 | 症状 | 解法 |
|---|---|---|---|
| 1 | PCIe 识别 | `lspci` 看不到卡 / 链路 `Width x0` | 换 CPU 直连 x16 槽 + **接 48V 辅助供电** |
| 2 | 固件 | `gaudi2-boot-fit.itb not found` | 安装 Intel Gaudi 软件栈 |
| 3 | SerDes 校验 | `bad SerDes type 65535` | **补丁①**：`return -EFAULT` → `dev_warn` |
| 4 | server_type | `synStatus=8 Device not found` | **补丁②**：`UNKNOWN` → `HL_SERVER_GAUDI2_HLS2` |
| 5 | 版本匹配 | `libhl_logger.so not found` | 驱动/固件/PyTorch 插件统一到 **1.18.0** |
| 6 | Shared Layer | `cannot initialize shared layer` | 手动编译缺失的 **`libhl-thunk.so`** |
| 7 | **RDMA / 互联** | `g_ibv.init() failed` / 0 个 netdev | **补丁③** + **`nic_ports_ext_mask=0`** |
| 8 | **图编译** | `synGraphCompile failed status 26` | **`source /etc/profile.d/habanalabs.sh`** |

> 第 8 层最隐蔽：图编译器不吐任何日志（`graph_compiler.log` 恒为 0 字节），
> 真实原因只是**环境变量没加载**（`GC_KERNEL_PATH` 等）。

---

## 🚀 快速开始

### 一键部署

```bash
git clone https://github.com/JChen-318/gaudi2-single-card-driver.git
cd gaudi2-single-card-driver

sudo ./install-gaudi2.sh
```

脚本会依次完成：环境预检 → 装驱动/固件 → 打补丁 → 配置模块参数 →
编译加载 → 验证 RDMA 链路 → 装 PyTorch 栈 → 配置环境 → 端到端验证。

### 常用变体

```bash
sudo ./install-gaudi2.sh --skip-pytorch    # 只装驱动
sudo ./install-gaudi2.sh --verify-only     # 只做验证（不改动系统）
sudo ./install-gaudi2.sh --help
```

### 日常使用

脚本会安装一个便捷命令 `hpu-run`：

```bash
hpu-run python3 your_script.py
```

等价于：

```bash
sudo bash -lc '
  source /etc/profile.d/habanalabs.sh
  export LD_PRELOAD=/lib/x86_64-linux-gnu/libtcmalloc.so.4
  python3 your_script.py
'
```

> ⚠️ **`source /etc/profile.d/habanalabs.sh` 是必须的**，否则图编译一定失败。

---

## 📁 文件说明

| 文件 | 说明 |
|---|---|
| **`install-gaudi2.sh`** | **一键部署/修复脚本**（8 个阶段，幂等，可重复运行） |
| **`部署手册.md`** | **操作手册**（850 行，照着做就能跑起来） |
| **`Gaudi2-HL225-排查全记录.md`** | 完整排查过程（1044 行，含源码级根因分析、每一环的证据链） |
| `patch-habanalabs.sh` | 单独重打驱动补丁（升级 `habanalabs-dkms` 后用） |
| `hputest.py` | 完整测试（4096 矩阵乘 + 激活 + 前向反向传播） |
| `mini.py` | 最小测试（4×4，用于快速排错） |

### 关于补丁

`install-gaudi2.sh` 会自动应用以下补丁（源码位置：
`/usr/src/habanalabs-<ver>/drivers/accel/habanalabs/gaudi2/gaudi2_cn.c`）：

```c
/* 补丁① + ②：绕过 bad SerDes 检查 + 修正 server_type */
	default:
		hdev->asic_prop.server_type = HL_SERVER_GAUDI2_HLS2;   /* PATCHED */
		if (get_from_fw && hdev->gaudi2_setup_type != GAUDI2_SETUP_TYPE_HLS3) {
			dev_err(hdev->dev, "bad SerDes type %d\n", serdes_type);
			dev_warn(hdev->dev, "PATCHED-ignore-bad-serdes");   /* 原来是 return -EFAULT */
		}
		break;

/* 补丁③：固件 link_mask=0 时不清零 ports_mask（否则 CN 不初始化 → 无 RDMA） */
		} else {
			if (cn_cpucp_info->link_mask[0]) {
				hdev->cn.ports_mask     &= cn_cpucp_info->link_mask[0];
				hdev->cn.ports_ext_mask &= cn_cpucp_info->link_ext_mask[0];
				hdev->cn.auto_neg_mask  &= cn_cpucp_info->auto_neg_mask[0];
			} else {
				dev_warn(hdev->dev,
					"PATCHED: FW link_mask=0, keeping ports_mask=0x%llx",
					(unsigned long long)hdev->cn.ports_mask);
			}
		}
```

模块参数（`/etc/modprobe.d/habanalabs-options.conf`）：

```bash
options habanalabs nic_ports_ext_mask=0
# 注意：不要加 card_type=0！它会把所有端口强制标成"外部"，抹掉 scale-up 端口
```

---

## 🔧 已验证环境

| 项 | 值 |
|---|---|
| 主板 | GIGABYTE `MU70-SU0-NV-XX` |
| BIOS | `R11` / 2020-08-19 |
| CPU | Intel Xeon `E5-2696 v3`（**单路**） |
| 系统 | Ubuntu 24.04.4 LTS |
| 内核 | `6.8.0-136-generic` |
| 加速卡 | Intel Gaudi2（OAM 模组 + NVIDIA OAM→PCIe 转接卡） |
| 显存 | **96 GB HBM2e** |
| PCIe | Gen3 x8（卡支持 Gen4 x16，受平台限制降速） |
| 驱动 | `habanalabs 1.18.0-524`（DKMS） |
| PyTorch | `2.4.0` + `habana-torch-plugin 1.18.0.524` |

---

## ⚠️ 已知限制

1. **平台不在 Intel 官方支持列表**（Haswell-EP 2014 vs 官方要求 Xeon Scalable 4/5 代）
2. **PCIe 带宽约为官方要求的 1/4**（Gen3 x8 vs Gen4 x16）→ 单卡推理/微调影响较小，多卡训练受限于互连
3. **硬件 SerDes 类型未知**：这是 OAM 模组的物理 strapping 决定的，只能通过补丁绕过
4. 补丁在 `habanalabs-dkms` 升级后会丢失，需用 `patch-habanalabs.sh` 重打
5. 脚本针对 **1.18.0 + Ubuntu 24.04 + kernel 6.8** 验证；其他版本需调整补丁行号

---

## 🔍 关键踩坑提醒

| 坑 | 一句话 |
|---|---|
| **供电** | 要 **48V/54V**，不是普通 PCIe 12V |
| **槽位** | 必须 CPU 直连 x16（单路机器上挂 CPU2 的槽是死的） |
| **DKMS** | 补丁要改 `/usr/src/`，**不是** `/var/lib/dkms/.../build/` |
| **模块参数** | `nic_ports_ext_mask=0` 必需，**`card_type=0` 千万别加** |
| **环境变量** | 跑程序前**必须** `source /etc/profile.d/habanalabs.sh` |
| **网卡名** | Habana 网卡叫 **`ens2*`**（异步创建），不叫 `hbl*` |
| **验证要点** | `cat /sys/class/infiniband/hbl_0/ext_ports_mask` **必须是 0** |
| **设备僵死** | 失败后显存不释放，需重载驱动或重启 |

完整排错表见 [`部署手册.md` §6](./部署手册.md)。

---

## 📖 延伸阅读

- [`部署手册.md`](./部署手册.md) —— 操作手册（含 20 条排错速查表）
- [`Gaudi2-HL225-排查全记录.md`](./Gaudi2-HL225-排查全记录.md) —— 完整排查过程
  - §4 最终因果链（每一环都有证据）
  - §7-SOLVED 互联问题完整解法
  - §8-SOLVED 图编译问题 + 环境变量坑

---

## ⚖️ 免责声明

本项目为**非官方**社区方案，针对特定硬件组合（OAM 转接卡 + 老平台）的踩坑总结。

- 修改内核驱动源码、绕过厂商校验**属于非官方做法**，可能带来稳定性风险
- 请自行评估并承担风险，**生产环境使用前请充分压测**
- 所有涉及 Intel Gaudi / Habana 的商标归 Intel Corporation 所有
- 本项目与 Intel Corporation 无任何关联

---

## 🤝 贡献

如果你在别的平台/转接卡/驱动版本上验证成功，欢迎提 Issue 或 PR 补充经验。

**特别欢迎：**
- 不同 OAM 转接卡的兼容性报告
- 其他驱动版本（1.19+ / 1.21+）的补丁适配
- `card_type` / `gaudi2_setup_type` 不同取值的效果对比
