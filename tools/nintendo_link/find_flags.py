import capstone
import struct

with open("tools/nintendo_link/wonder.ko", "rb") as f:
    elf = f.read()

# Parse sections
e_shoff = struct.unpack_from("<Q", elf, 40)[0]
e_shentsize = struct.unpack_from("<H", elf, 58)[0]
e_shnum = struct.unpack_from("<H", elf, 60)[0]
e_shstrndx = struct.unpack_from("<H", elf, 62)[0]

sections = []
for i in range(e_shnum):
    offset = e_shoff + i * e_shentsize
    sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size, sh_link, sh_info, sh_addralign, sh_entsize = struct.unpack_from("<IIQQQQIIQQ", elf, offset)
    sections.append({
        "idx": i, "name_idx": sh_name, "type": sh_type, "flags": sh_flags,
        "addr": sh_addr, "offset": sh_offset, "size": sh_size, "link": sh_link
    })

shstr = elf[sections[e_shstrndx]["offset"]:sections[e_shstrndx]["offset"]+sections[e_shstrndx]["size"]]
for s in sections:
    name_end = shstr.find(b"\x00", s["name_idx"])
    s["name"] = shstr[s["name_idx"]:name_end].decode("latin1")

# Find text section
text_sec = next(s for s in sections if s["name"] == ".text")
text_data = elf[text_sec["offset"]:text_sec["offset"]+text_sec["size"]]

md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)

# Find symbols in text
symtab_sec = next(s for s in sections if s["type"] == 2)
strtab_sec = sections[symtab_sec["link"]]
strtab = elf[strtab_sec["offset"]:strtab_sec["offset"]+strtab_sec["size"]]

symbols = []
num_syms = symtab_sec["size"] // 24
for i in range(num_syms):
    off = symtab_sec["offset"] + i * 24
    st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", elf, off)
    name_end = strtab.find(b"\x00", st_name)
    sym_name = strtab[st_name:name_end].decode("latin1")
    if sym_name and st_shndx == text_sec["idx"]:
        symbols.append((st_value, sym_name))

symbols.sort()

def get_sym(addr):
    cur = "unknown"
    for v, n in symbols:
        if v <= addr:
            cur = n
        else:
            break
    return cur

print("Searching for instructions modifying offset 0x48 or orr with flags...")
for ins in md.disasm(text_data, 0):
    if "0x48" in ins.op_str:
        print(f"[{get_sym(ins.address)}] 0x{ins.address:04x}: {ins.mnemonic} {ins.op_str}")
