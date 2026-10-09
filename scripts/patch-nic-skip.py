#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
补丁④(诊断用):在 hl_cn_init 里提前返回,完全跳过 NIC 初始化
目的:验证 panic 是否由 CN/NIC 子系统引起

用法: sudo python3 patch-nic-skip.py           # 应用
      sudo python3 patch-nic-skip.py --revert  # 撤销
"""
import os, sys, re, glob, shutil

TAB = "\t"
APPLY = "--revert" not in sys.argv

def find_src():
    cands = [d for d in glob.glob("/usr/src/habanalabs-*")
             if os.path.isdir(d) and not d.endswith(".bak")
             and not d.endswith(".ORIG")
             and os.path.isdir(os.path.join(d, "drivers"))]
    if not cands:
        sys.exit("找不到源码目录")
    def key(d):
        m = re.search(r"habanalabs-([0-9.]+)-", d)
        return [int(x) for x in m.group(1).split(".")] if m else [0]
    return sorted(cands, key=key)[-1]

SRC = find_src()
CN = os.path.join(SRC, "drivers/accel/habanalabs/cn/cn.c")
print("=" * 64)
print("目标: %s" % CN)
print("模式: %s" % ("应用补丁④(跳过 NIC 初始化)" if APPLY else "撤销补丁④"))
print("=" * 64)

if not os.path.isfile(CN):
    sys.exit("找不到 cn.c")

bak = CN + ".ORIG_NICSKIP"
if not os.path.exists(bak):
    shutil.copy2(CN, bak); print("[备份] %s" % bak)

with open(CN, "rb") as f:
    text = f.read().decode("utf-8", errors="surrogateescape")

MARK = "PATCHED-NIC-SKIP"
# hl_cn_init 里 "check if the NIC is enabled" 之后的提前返回
OLD = (
    "\t/* check if the NIC is enabled */\n"
    "\tif (!hdev->cn.ports_mask)\n"
    "\t\treturn 0;\n"
)
NEW = (
    "\t/* check if the NIC is enabled */\n"
    "\tif (!hdev->cn.ports_mask)\n"
    "\t\treturn 0;\n"
    "\n"
    "\t/* " + MARK + ": 单卡无互联,完全跳过 NIC 初始化(诊断用) */\n"
    "\thl_info(hdev, \"" + MARK + ": skipping NIC init entirely\");\n"
    "\treturn 0;\n"
)

if APPLY:
    if MARK in text:
        print("\n[跳过] 补丁已存在")
    else:
        n = text.count(OLD)
        print("\n匹配到 %d 处 'check if the NIC is enabled' 块" % n)
        if n == 0:
            print("  ✗ 未找到匹配,可能代码已变")
        else:
            # 只替换 hl_cn_init 里的那一处(它是最靠后的一处)
            idx = text.rfind(OLD)
            text = text[:idx] + NEW + text[idx + len(OLD):]
            print("  ✓ 已在偏移 %d 处插入提前返回" % idx)
else:
    if MARK not in text:
        print("\n[跳过] 补丁不存在")
    else:
        text = text.replace(NEW, OLD)
        print("\n  ✓ 已撤销补丁④")

with open(CN, "wb") as f:
    f.write(text.encode("utf-8", errors="surrogateescape"))

# 校验
with open(CN, "rb") as f:
    check = f.read().decode("utf-8", errors="surrogateescape")
print("\n--- 校验 ---")
print("  %-24s : %s" % (MARK, "存在" if MARK in check else "不存在"))
print("  pre_core_init            : %s" % ("存在" if "pre_core_init" in check else "不存在"))
print("  set_hw_cap               : %s" % ("存在" if "set_hw_cap" in check else "不存在"))
for o, c in (("{", "}"), ("(", ")")):
    a, b = check.count(o), check.count(c)
    print("  %s%s 配平 : %s (%d/%d)" % (o, c, "OK" if a == b else "✗", a, b))
