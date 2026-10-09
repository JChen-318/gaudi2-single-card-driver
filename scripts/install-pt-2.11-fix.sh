#!/bin/bash
# ============================================================
# 修正版:安装 Gaudi PyTorch 2.11 + habana 1.24.1.482
# 关键:必须以 root 运行(装到 /usr/local),且本地 torch wheel 最后装
# ============================================================
set -u
LOG=/home/user/install-pt-2.11-fix.log
exec > >(tee -a "$LOG") 2>&1
PROXY=http://192.168.1.20:8888
PT=/home/user/ptmods
PY=python3.12
PIP="$PY -m pip"
PIPOPT="--proxy $PROXY --disable-pip-version-check --no-warn-script-location"

if [ "$(id -u)" != "0" ]; then
    echo "❌ 必须以 root 运行: sudo $0"; exit 1
fi

echo "=================================================="
echo "=== $(date) 修正安装 PyTorch 2.11 + habana 1.24.1 ==="
echo "=== 目标位置: /usr/local/lib/python3.12/dist-packages ==="
echo "=================================================="
cd "$PT" || exit 1

echo
echo "--- [0/6] 清理 ~/.local 里错误的安装(user a) ---"
su - a -c "python3.12 -m pip uninstall -y torch torchvision torchaudio habana_torch_plugin habana_gpu_migration habana_torch_dataloader 2>&1 | grep -E 'Successfully|WARNING|not installed|Skipping' | tail -12" 2>&1
echo "  剩余 user site 包:"
ls /home/user/.local/lib/python3.12/site-packages/ 2>/dev/null | grep -iE '^(torch|habana)' | head || echo "    (无)"

echo
echo "--- [1/6] 卸载 /usr/local 里的旧/错版本 ---"
$PIP uninstall -y torch torchvision torchaudio \
    habana_torch_plugin habana-torch-plugin \
    habana_gpu_migration habana-torch-dataloader 2>&1 | grep -E 'Successfully|WARNING|not installed|Skipping' | tail -20

echo
echo "--- [2/6] habana-pyhlml 1.24.1.482 ---"
$PIP install $PIPOPT "habana-pyhlml==1.24.1.482" 2>&1 | tail -4

echo
echo "--- [3/6] torchvision 0.26.0 + 依赖(此时不装本地 torch) ---"
$PIP install $PIPOPT --no-cache-dir "torchvision==0.26.0" \
    --index-url https://download.pytorch.org/whl/cpu 2>&1 | tail -6

echo
echo "--- [4/6] ★ 本地 wheels(含 Habana torch)必须最后装,覆盖上去 ★ ---"
$PIP install $PIPOPT --no-deps --force-reinstall \
    ./torch-2.11.0a0+git009b5f6-cp312-cp312-linux_x86_64.whl 2>&1 | tail -5
$PIP install $PIPOPT --no-deps --force-reinstall \
    ./habana_torch_plugin-1.24.1.482-cp312-cp312-linux_x86_64.whl \
    ./habana_gpu_migration-1.24.1.482-cp312-cp312-linux_x86_64.whl \
    ./habana_torch_dataloader-1.24.1.482-py3-none-any.whl \
    ./torch_tb_profiler-0.4.0-py3-none-any.whl \
    ./neural_compressor_pt-3.6-py3-none-any.whl \
    ./intel_transformer_engine-1.24.1.482-py2.py3-none-any.whl 2>&1 | tail -6

echo
echo "--- [5/6] requirements-pytorch.txt ---"
$PIP install $PIPOPT -r requirements-pytorch.txt 2>&1 | tail -5

echo
echo "--- [6/6] ★ 再次确认 Habana torch 没被顶掉 ★ ---"
$PIP install $PIPOPT --no-deps --force-reinstall \
    ./torch-2.11.0a0+git009b5f6-cp312-cp312-linux_x86_64.whl 2>&1 | tail -3

echo
echo "=============== 验证 ==============="
$PY -c "
import torch, sys
print('python      :', sys.version.split()[0])
print('executable  :', sys.executable)
print('torch       :', torch.__version__)
print('torch路径    :', torch.__file__)
assert '+cpu' not in torch.__version__, 'FAIL: 装成上游 CPU 版了!'
assert 'git' in torch.__version__ or 'a0' in torch.__version__, 'FAIL: 不是 Habana fork!'
print('  -> torch 是 Habana fork OK')
import habana_frameworks.torch as ht
import habana_frameworks.torch.hpu as hthpu
print('habana插件   : 导入成功')
print('HPU 可用     :', hthpu.is_available())
print('HPU 数量     :', hthpu.device_count())
if hthpu.is_available():
    print('HPU 设备名   :', hthpu.get_device_name(0))
try:
    import torchvision; print('torchvision  :', torchvision.__version__)
except Exception as e: print('torchvision  :', repr(e))
"
echo
echo "--- 安装位置确认 ---"
echo -n "  /usr/local 里的 torch: "; ls -d /usr/local/lib/python3.12/dist-packages/torch 2>/dev/null || echo '无'
echo -n "  ~/.local  里的 torch: "; ls -d /home/user/.local/lib/python3.12/site-packages/torch 2>/dev/null || echo '无(正确)'
echo
echo "=================================================="
echo "=== $(date) 完成  日志: $LOG ==="
echo "=================================================="
