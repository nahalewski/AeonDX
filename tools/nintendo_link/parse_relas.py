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

# Find rela sections
symtab = next(s for s in sections if s["type"] == 2)
strtab = elf[sections[symtab["link"]]["offset"]:]
symbols = []
for i in range(symtab["size"] // 24):
    off = symtab["offset"] + i * 24
    st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", elf, off)
    name = strtab[st_name:strtab.find(b"\x00", st_name)].decode("latin1")
    symbols.append((name, st_value, st_shndx))

# Find relocations targeting the section holding wonder_vendor_cmds
cmds_sec_idx = None
cmds_offset = None
for name, val, shndx in symbols:
    if name == "wonder_vendor_cmds":
        cmds_sec_idx = shndx
        cmds_offset = val
        break

print(f"wonder_vendor_cmds in section {cmds_sec_idx} ({sections[cmds_sec_idx]['name']}) at offset {hex(cmds_offset)}")

rela_sec = next((s for s in sections if s["type"] == 4 and s["info"] == cmds_sec_idx), None) # SHT_RELA
if rela_sec:
    num_rela = rela_sec["size"] // 24
    for i in range(num_rela):
        r_offset, r_info, r_addend = struct.unpack_from("<QQq", elf, rela_sec["offset"] + i * 24)
        if cmds_offset <= r_offset < cmds_offset + 672:
            sym_idx = r_info >> 32
            rel_sym = symbols[sym_idx][0]
            field_idx = (r_offset - cmds_offset) // 56
            field_off = (r_offset - cmds_offset) % 56
            print(f"Cmd index {field_idx} + {field_off}: -> {rel_sym} (addend {r_addend})")
