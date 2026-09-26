import struct

with open("tools/nintendo_link/wonder.ko", "rb") as f:
    elf = f.read()

# Load sections
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
    symbols[name] = (st_value, st_size, st_shndx)

def dump_policy(name):
    val, size, shndx = symbols[name]
    sec = sections[shndx]
    data = elf[sec["offset"] + val : sec["offset"] + val + size]
    print(f"\n--- Policy {name} (size {size}) ---")
    # struct nla_policy { u8 type; u8 validation_type; u16 len; ... } in Linux kernel
    # size of struct nla_policy in 64-bit kernel is usually 16 or 24 bytes
    # Let's dump bytes
    for i in range(0, size, 16):
        print(f"Attr {i//16}: {data[i:i+16].hex(' ')}")

dump_policy("wonder_set_frequency_policy")
dump_policy("wonder_filter_params_policy")
dump_policy("wonder_fixed_rate_policy")
dump_policy("wonder_set_reg_policy")
