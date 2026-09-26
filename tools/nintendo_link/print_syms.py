import struct

with open("tools/nintendo_link/wonder.ko", "rb") as f:
    elf = f.read()

symtab_sec = None
strtab_sec = None
e_shoff = struct.unpack_from("<Q", elf, 40)[0]
e_shentsize = struct.unpack_from("<H", elf, 58)[0]
e_shnum = struct.unpack_from("<H", elf, 60)[0]

sections = []
for i in range(e_shnum):
    offset = e_shoff + i * e_shentsize
    sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size, sh_link, sh_info, sh_addralign, sh_entsize = struct.unpack_from("<IIQQQQIIQQ", elf, offset)
    sections.append({"type": sh_type, "offset": sh_offset, "size": sh_size, "link": sh_link})

symtab = next(s for s in sections if s["type"] == 2)
strtab = sections[symtab["link"]]
sdata = elf[strtab["offset"]:strtab["offset"]+strtab["size"]]

num_syms = symtab["size"] // 24
for i in range(num_syms):
    off = symtab["offset"] + i * 24
    st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", elf, off)
    name_end = sdata.find(b"\x00", st_name)
    sym_name = sdata[st_name:name_end].decode("latin1")
    if sym_name and not sym_name.startswith("$") and not sym_name.startswith("__"):
        print(f"{sym_name} @ {hex(st_value)} (size {st_size})")
