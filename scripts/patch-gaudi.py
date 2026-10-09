#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
为 habanalabs 驱动打 3 个补丁（版本无关，1.18.0 / 1.24.1 都适用）
用法: sudo python3 /home/user/patch-gaudi.py [版本号]
"""
import os, sys, glob, re, shutil

def find_src():
    if len(sys.argv) > 1:
        d = "/usr/src/habanalabs-%s" % sys.argv[1]
        if os.path.isdir(d):
            return d
        sys.exit("找不到源码目录: %s" % d)
    cands = [d for d in glob.glob("/usr/src/habanalabs-*")
             if os.path.isdir(d) and not d.endswith(".bak")
             and not d.endswith(".ORIG") and os.path.isdir(os.path.join(d, "drivers"))]
    if not cands:
        sys.exit("找不到任何 habanalabs 源码目录")
    def key(d):
        m = re.search(r"habanalabs-([0-9.]+)-", d)
        return [int(x) for x in m.group(1).split(".")] if m else [0]
    return sorted(cands, key=key)[-1]

SRC = find_src()
CN = os.path.join(SRC, "drivers/accel/habanalabs/gaudi2/gaudi2_cn.c")
print("=" * 64)
print("源码目录 : %s" % SRC)
print("目标文件 : %s" % CN)
print("=" * 64)

if not os.path.isfile(CN):
    sys.exit("[X] 找不到 gaudi2_cn.c")

# ---------- 备份 ----------
bak = CN + ".ORIG"
if not os.path.exists(bak):
    shutil.copy2(CN, bak)
    print("[备份] %s" % bak)
else:
    print("[备份] 已存在,跳过")

with open(CN, "rb") as f:
    text = f.read().decode("utf-8", errors="surrogateescape")
orig = text

# ============================================================
# 补丁①②：绕过 bad SerDes 检查 + 修正 server_type
# ============================================================
P12_OLD = (
    "\tdefault:\n"
    "\t\thdev->asic_prop.server_type = HL_SERVER_TYPE_UNKNOWN;\n"
    "\n"
    "\t\t/* SW-169172: For HLS3 setup don't fail device init on invalid serdes_type. */\n"
    "\t\tif (get_from_fw && hdev->gaudi2_setup_type != GAUDI2_SETUP_TYPE_HLS3) {\n"
    "\t\t\thl_err(hdev, \"bad SerDes type %d\\n\", serdes_type);\n"
    "\t\t\treturn -EFAULT;\n"
    "\t\t}\n"
)
P12_NEW = (
    "\tdefault:\n"
    "\t\thdev->asic_prop.server_type = HL_SERVER_GAUDI2_HLS2; /*PATCHED*/\n"
    "\n"
    "\t\t/* SW-169172: For HLS3 setup don't fail device init on invalid serdes_type. */\n"
    "\t\tif (get_from_fw && hdev->gaudi2_setup_type != GAUDI2_SETUP_TYPE_HLS3) {\n"
    "\t\t\thl_err(hdev, \"bad SerDes type %d\\n\", serdes_type);\n"
    "\t\t\tdev_warn(hdev->dev, \"PATCHED-ignore-bad-serdes\");\n"
    "\t\t}\n"
)

# ============================================================
# 补丁③：固件 link_mask=0 时不清零 ports_mask
# ============================================================
P3_OLD = (
    "\t\t} else {\n"
    "\t\t\thdev->cn.ports_mask &= cn_cpucp_info->link_mask[0];\n"
    "\t\t\thdev->cn.ports_ext_mask &= cn_cpucp_info->link_ext_mask[0];\n"
    "\t\t\thdev->cn.auto_neg_mask &= cn_cpucp_info->auto_neg_mask[0];\n"
    "\t\t}\n"
)
P3_NEW = (
    "\t\t} else {\n"
    "\t\t\tif (cn_cpucp_info->link_mask[0]) {\n"
    "\t\t\t\thdev->cn.ports_mask &= cn_cpucp_info->link_mask[0];\n"
    "\t\t\t\thdev->cn.ports_ext_mask &= cn_cpucp_info->link_ext_mask[0];\n"
    "\t\t\t\thdev->cn.auto_neg_mask &= cn_cpucp_info->auto_neg_mask[0];\n"
    "\t\t\t} else {\n"
    "\t\t\t\tdev_warn(hdev->dev,\n"
    "\t\t\t\t\t\"PATCHED: FW link_mask=0, keeping ports_mask=0x%llx\",\n"
    "\t\t\t\t\t(unsigned long long)hdev->cn.ports_mask);\n"
    "\t\t\t}\n"
    "\t\t}\n"
)

results = []

def apply(name, old, new, marker):
    global text
    if marker in text:
        results.append((name, "已打过(跳过)"))
        return
    n = text.count(old)
    if n == 0:
        results.append((name, "[X] 未找到匹配"))
        return
    if n > 1:
        results.append((name, "[!] 匹配 %d 处,只改第一处" % n))
        text = text.replace(old, new, 1)
        return
    text = text.replace(old, new, 1)
    results.append((name, "[OK] 已应用"))

apply("①②", P12_OLD, P12_NEW, "/*PATCHED*/")
apply("③", P3_OLD, P3_NEW, "PATCHED: FW link_mask=0")

print()
for name, r in results:
    print("  补丁 %-4s %s" % (name, r))

if text != orig:
    with open(CN, "wb") as f:
        f.write(text.encode("utf-8", errors="surrogateescape"))
    print("\n[写入] 文件已更新")
else:
    print("\n[跳过] 文件无变化")

# ---------- 校验 ----------
with open(CN, "rb") as f:
    check = f.read().decode("utf-8", errors="surrogateescape")
print("\n--- 校验 ---")
print("  PATCHED 标记数          : %d" % check.count("PATCHED"))
print("  server_type 已修正      : %s" % ("是" if "HL_SERVER_GAUDI2_HLS2" in check else "否"))
print("  bad SerDes 不再 return  : %s" % ("是" if "return -EFAULT" not in check else "否 [X] 补丁① 未生效"))
a, b = check.count("{"), check.count("}")
c1, c2 = check.count("("), check.count(")")
print("  { } 配平                : %s (%d/%d)" % ("OK" if a == b else "[X]", a, b))
print("  ( ) 配平                : %s (%d/%d)" % ("OK" if c1 == c2 else "[X]", c1, c2))
