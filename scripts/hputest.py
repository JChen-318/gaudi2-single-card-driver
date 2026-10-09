import torch
import habana_frameworks.torch.core as htcore

print("torch              :", torch.__version__)
print("hpu.is_available() :", torch.hpu.is_available())
print("hpu.device_count() :", torch.hpu.device_count())
try:
    print("hpu device name    :", torch.hpu.get_device_name(0))
except Exception as e:
    print("hpu device name    : n/a")

a = torch.randn(4096, 4096, device="hpu")
b = torch.randn(4096, 4096, device="hpu")
c = a @ b
htcore.mark_step()
print("matmul 4096x4096   : OK, sum =", float(c.sum().cpu()))

d = torch.nn.functional.relu(c)
htcore.mark_step()
print("relu               : OK, max =", float(d.max().cpu()))

# 小网络前向 + 反向
net = torch.nn.Sequential(
    torch.nn.Linear(1024, 2048),
    torch.nn.ReLU(),
    torch.nn.Linear(2048, 10),
).to("hpu")
x = torch.randn(64, 1024, device="hpu")
y = net(x).sum()
y.backward()
htcore.mark_step()
print("fwd+bwd            : OK, loss =", float(y.detach().cpu()))

print("RESULT: HPU WORKS")
