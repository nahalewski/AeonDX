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
    sections.append({"idx": i, "name_idx": sh_name, "type": sh_type, "offset": sh_offset, "size": sh_size, "link": sh_link, "info": sh_info})

shstr = elf[sections[struct.unpack_from("<H", elf, 62)[0]]["offset"]:]
for s in sections:
    s["name"] = shstr[s["name_idx"]:shstr.find(b"\x00", s["name_idx"])].decode("latin1")

text_sec_idx = next(i for i, s in enumerate(sections) if s["name"] == ".text")
rela_sec = next(s for s in sections if s["type"] == 4 and s["info"] == text_sec_idx)

symtab = next(s for s in sections if s["type"] == 2)
strtab = elf[sections[symtab["link"]]["offset"]:]
symbols = []
for i in range(symtab["size"] // 24):
    off = symtab["offset"] + i * 24
    st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", elf, off)
    name = strtab[st_name:strtab.find(b"\x00", st_name)].decode("latin1")
    symbols.append((name, st_value, st_shndx))

rodata_sec = next(s for s in sections if s["name"] == ".rodata")
rodata = elf[rodata_sec["offset"]:rodata_sec["offset"]+rodata_sec["size"]]

num_rela = rela_sec["size"] // 24
for i in range(num_rela):
    r_offset, r_info, r_addend = struct.unpack_from("<QQq", elf, rela_sec["offset"] + i * 24)
    if 0x2358 <= r_offset <= 0x2800:
        sym_idx = r_info >> 32
        sym_name, sym_val, sym_shndx = symbols[sym_idx]
        if sym_shndx == rodata_sec["idx"]:
            str_off = sym_val + r_addend
            end = rodata.find(b"\x00", str_off)
            print(f"0x{r_offset:04x}: rodata -> {rodata[str_off:end].decode('latin1', errors='replace')}")
        else:
            print(f"0x{r_offset:04x}: sym -> {sym_name} (addend {r_addend})")
