import struct

with open("tools/nintendo_link/wonder.ko", "rb") as f:
    elf = f.read()

# Load symbols and text
e_shoff = struct.unpack_from("<Q", elf, 40)[0]
e_shentsize = struct.unpack_from("<H", elf, 58)[0]
e_shnum = struct.unpack_from("<H", elf, 60)[0]
sections = []
for i in range(e_shnum):
    offset = e_shoff + i * e_shentsize
    sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size, sh_link, sh_info, sh_addralign, sh_entsize = struct.unpack_from("<IIQQQQIIQQ", elf, offset)
    sections.append({"idx": i, "name_idx": sh_name, "type": sh_type, "offset": sh_offset, "size": sh_size, "link": sh_link})

shstr = elf[sections[struct.unpack_from("<H", elf, 62)[0]]["offset"]:]
for s in sections:
    s["name"] = shstr[s["name_idx"]:shstr.find(b"\x00", s["name_idx"])].decode("latin1")

symtab = next(s for s in sections if s["type"] == 2)
strtab = elf[sections[symtab["link"]]["offset"]:]

symbols = {}
for i in range(symtab["size"] // 24):
    off = symtab["offset"] + i * 24
    st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", elf, off)
    name = strtab[st_name:strtab.find(b"\x00", st_name)].decode("latin1")
    if name:
        symbols[name] = (st_value, st_size, st_shndx)

val, size, shndx = symbols["wonder_vendor_cmds"]
sec = sections[shndx]
data = elf[sec["offset"] + val : sec["offset"] + val + size]

# In struct nl80211_vendor_cmd_info:
# struct nl80211_vendor_cmd_info { u32 vendor_id; u32 subcmd; } or similar in Linux kernel cfg80211!
# In 64-bit kernel:
# struct wiphy_vendor_command {
#   struct nl80211_vendor_cmd_info info; // u32 vendor_id, u32 subcmd
#   u32 flags;
#   int (*doit)(struct wiphy *wiphy, struct wireless_dev *wdev, const void *data, int len);
#   int (*dumpit)(...);
#   const struct nla_policy *policy;
#   u32 maxattr;
# };
print(f"wonder_vendor_cmds at {hex(val)}, size {size}")
entry_size = 56 # typical 64-bit wiphy_vendor_command
for i in range(size // entry_size):
    chunk = data[i*entry_size : (i+1)*entry_size]
    vid, subcmd, flags = struct.unpack_from("<III", chunk, 0)
    doit = struct.unpack_from("<Q", chunk, 16)[0]
    print(f"Cmd {i}: vendor_id=0x{vid:06x}, subcmd={subcmd}, flags=0x{flags:x}, doit={hex(doit)}")
