import capstone
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

text_sec = next(s for s in sections if s["name"] == ".text")
symtab = next(s for s in sections if s["type"] == 2)
strtab = elf[sections[symtab["link"]]["offset"]:]

symbols = {}
for i in range(symtab["size"] // 24):
    off = symtab["offset"] + i * 24
    st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", elf, off)
    name = strtab[st_name:strtab.find(b"\x00", st_name)].decode("latin1")
    if name:
        symbols[name] = (st_value, st_size, st_shndx)

md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)

funcs = ["wondertap_set_bssid_filter", "wondertap_channel_schedule_request", "wondertap_set_station_info"]
for fn in funcs:
    if fn in symbols:
        val, size, shndx = symbols[fn]
        sec = sections[shndx]
        code = elf[sec["offset"] + val : sec["offset"] + val + size]
        print(f"\n=== {fn} (addr {hex(val)}, size {size}) ===")
        for ins in md.disasm(code, val):
            if "0x48" in ins.op_str or "#4" in ins.op_str or "orr" in ins.mnemonic:
                print(f"0x{ins.address:04x}: {ins.mnemonic} {ins.op_str}")
