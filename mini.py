import os
import torch
import habana_frameworks.torch.core as htcore

print("torch           :", torch.__version__)
print("is_available    :", torch.hpu.is_available())
print("device_count    :", torch.hpu.device_count())
try:
    print("device_name     :", torch.hpu.get_device_name(0))
except Exception as e:
    print("device_name     : n/a", e)

a = torch.randn(4, 4, device="hpu")
print("randn on hpu    : OK")
htcore.mark_step()
print("mark_step       : OK")

b = (a + 1).cpu()
print("cpu()           : OK", tuple(b.shape))
print("RESULT: HPU COMPUTE OK")
