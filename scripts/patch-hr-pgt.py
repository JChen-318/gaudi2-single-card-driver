#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
补丁⑤(修复怀疑的根因):
把 Gaudi2 的 PMMU 页表从 "主机内存驻留" 改回 "设备 DRAM 驻留"

背景:
  1.24.1 新增 host-resident page table 机制,gaudi2.c 里设置:
      prop->pmmu.host_resident = 1;    ← 设备往主机内存写 PTE
  1.18.0 没有这个字段(默认 0 = 设备 DRAM 驻留),工作正常。

  → 疑似:该卡上主机内存页表的分配/映射有 bug,设备把 PTE 写进了
    CPU 页表页 → "Corrupted page table" → panic。

用法: sudo python3 patch-hr-pgt.py [--revert]
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
G2 = os.path.join(SRC, "drivers/accel/habanalabs/gaudi2/gaudi2.c")
print("=" * 66)
print("目标: %s" % G2)
print("模式: %s" % ("应用补丁⑤ (PMMU 页表改回设备 DRAM)" if APPLY else "撤销补丁⑤"))
print("=" * 66)

if not os.path.isfile(G2):
    sys.exit("找不到 gaudi2.c")

bak = G2 + ".ORIG_HRPGT"
if not os.path.exists(bak):
    shutil.copy2(bak.replace(".ORIG_HRPGT", ""), bak) if False else shutil.copy2(G2, bak)
    print("[备份] %s" % bak)

with open(G2, "rb") as f:
    text = f.read().decode("utf-8", errors="surrogateescape")

MARK = "PATCHED-HRPGT"
OLD = TAB + "prop->pmmu.host_resident = 1;\n"
NEW = (TAB + "prop->pmmu.host_resident = 0; /* " + MARK
       + ": 改回设备 DRAM 驻留(1.18.0 行为),规避主机页表被踩 */\n")

print("\n--- 当前所有 host_resident 设置 ---")
for i, line in enumerate(text.split("\n"), 1):
    if "host_resident" in line and "=" in line and "==" not in line:
        print("  %5d: %s" % (i, line.strip()))

if APPLY:
    if MARK in text:
        print("\n[跳过] 补丁已存在")
    else:
        n = text.count(OLD)
        print("\n匹配 'prop->pmmu.host_resident = 1;' : %d 处" % n)
        if n == 0:
            print("  ✗ 未找到(可能已改或版本不同)")
        else:
            text = text.replace(OLD, NEW, 1)
            print("  ✓ 已改为 host_resident = 0")
else:
    if MARK not in text:
        print("\n[跳过] 补丁不存在")
    else:
        text = text.replace(NEW, OLD)
        print("\n  ✓ 已撤销")

with open(G2, "wb") as f:
    f.write(text.encode("utf-8", errors="surrogateescape"))

with open(G2, "rb") as f:
    check = f.read().decode("utf-8", errors="surrogateescape")
print("\n--- 校验 ---")
print("  %-16s : %s" % (MARK, "存在" if MARK in check else "不存在"))
for i, line in enumerate(check.split("\n"), 1):
    if "host_resident" in line and "=" in line and "==" not in line:
        print("  %5d: %s" % (i, line.strip()))
