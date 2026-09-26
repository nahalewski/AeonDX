import capstone
import struct

with open("tools/nintendo_link/wonder.ko", "rb") as f:
    elf = f.read()

# Parse 64-bit ELF header
assert elf[:4] == b"\x7fELF"
e_shoff = struct.unpack_from("<Q", elf, 40)[0]
e_shentsize = struct.unpack_from("<H", elf, 58)[0]
e_shnum = struct.unpack_from("<H", elf, 60)[0]
e_shstrndx = struct.unpack_from("<H", elf, 62)[0]

# Section headers
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

# Find symtab
symtab_sec = next(s for s in sections if s["type"] == 2) # SHT_SYMTAB
strtab_sec = sections[symtab_sec["link"]]
strtab = elf[strtab_sec["offset"]:strtab_sec["offset"]+strtab_sec["size"]]

symbols = {}
num_syms = symtab_sec["size"] // 24
for i in range(num_syms):
    off = symtab_sec["offset"] + i * 24
    st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", elf, off)
    name_end = strtab.find(b"\x00", st_name)
    sym_name = strtab[st_name:name_end].decode("latin1")
    if sym_name:
        symbols[sym_name] = (st_value, st_size, st_shndx)

print("Symbols found:", [k for k in symbols if "wondertap" in k])

# Disassemble wondertap_init
if "wondertap_init" in symbols:
    val, size, shndx = symbols["wondertap_init"]
    sec = sections[shndx]
    code = elf[sec["offset"] + val : sec["offset"] + val + size]
    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
    print(f"\n--- Disassembly of wondertap_init (size {size}) ---")
    for ins in md.disasm(code, val):
        print(f"0x{ins.address:04x}: {ins.mnemonic} {ins.op_str}")
