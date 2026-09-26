import re

with open("tools/nintendo_link/wonder.ko", "rb") as f:
    data = f.read()

matches = re.findall(b"[\x20-\x7e]{4,}", data)
for m in matches:
    s = m.decode("latin1")
    if any(k in s.lower() for k in ["vendor", "subcmd", "wondertap", "flags", "filter", "freq", "setting", "init failed"]):
        print(s)
