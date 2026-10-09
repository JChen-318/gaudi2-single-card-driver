#!/usr/bin/env python3
"""netconsole 接收端 —— 实时接收服务器内核日志(UDP 6666)"""
import socket, sys, datetime

LOG = r"C:\Users\1\gaudi-relay\netconsole-capture.log"
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("0.0.0.0", 6666))
except Exception as e:
    print("bind 失败: %s" % e); sys.exit(1)
print("netconsole 监听中: UDP 0.0.0.0:6666  ->  %s" % LOG, flush=True)
f = open(LOG, "a", encoding="utf-8", errors="replace")
f.write("\n===== netconsole 会话开始 %s =====\n" % datetime.datetime.now())
f.flush()
while True:
    try:
        data, addr = s.recvfrom(65535)
        ts = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
        line = "[%s] %s" % (ts, data.decode("utf-8", errors="replace").rstrip())
        print(line, flush=True)
        f.write(line + "\n"); f.flush()
    except KeyboardInterrupt:
        break
    except Exception as e:
        print("recv 错误: %s" % e, flush=True)
f.close()
