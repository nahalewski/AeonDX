import struct

with open("tools/nintendo_link/wonder.ko", "rb") as f:
    data = f.read()

target = b"Init failed: Missing cached settings"
idx = data.find(target)
print("Index of string:", idx)

# Find references to this string offset
# In 64-bit ELF, let us search for rodata section and text references or ADRP/ADD instructions
import re
print("Found target string at offset", hex(idx))
