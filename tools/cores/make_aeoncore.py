#!/usr/bin/env python3
"""Packs an emulator core as a .aeoncore (the format fold3ds/cores.lua installs)
and prints its line for the cores catalogue (catalog.txt).

    python3 tools/cores/make_aeoncore.py --id fceumm --name "FCEUmm" \\
        --systems nes --extensions "nes|fds|unf|unif" --version 20260926 \\
        --lib fceumm_libretro_android.so --license COPYING --source URL \\
        --sub "NES and Famicom Disk System" --out dist

A .aeoncore is a zip: aeoncore.txt (key=value), lib/arm64-v8a/<the .so>,
LICENSE.  The catalogue line: id, file, size, sha256, name, systems, version,
sub -- tab separated.
"""
import argparse
import hashlib
import os
import zipfile

FORMAT = 1


def pack(a):
    os.makedirs(a.out, exist_ok=True)
    lib = a.lib_name or ("lib/arm64-v8a/" + os.path.basename(a.lib))
    manifest = [
        "format=%d" % FORMAT,
        "id=" + a.id,
        "name=" + a.name,
        "version=" + a.version,
        "kind=" + a.kind,
        "systems=" + a.systems,
        "extensions=" + a.extensions,
        "lib=" + lib,
        "license=" + a.license_name,
        "source=" + a.source,
    ]
    for kv in a.set or []:
        manifest.append(kv)
    for pair in a.ext_system or []:
        ext, sys = pair.split(":")
        manifest.append("ext_%s=%s" % (ext.lower(), sys))
    name = a.id + ".aeoncore"
    path = os.path.join(a.out, name)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("aeoncore.txt", "\n".join(manifest) + "\n")
        z.write(a.lib, lib)
        for pair in a.extra or []:
            src, arc = pair.split("::")
            if os.path.abspath(src) != os.path.abspath(a.lib):
                z.write(src, arc)
        if a.license and os.path.exists(a.license):
            z.write(a.license, "LICENSE")
    data = open(path, "rb").read()
    line = "\t".join([a.id, name, str(len(data)), hashlib.sha256(data).hexdigest(), a.name, a.systems,
                      a.version, a.sub or ""])
    return path, line


def main():
    p = argparse.ArgumentParser()
    for k in ("id", "name", "systems", "extensions", "version", "lib", "out"):
        p.add_argument("--" + k, required=True)
    p.add_argument("--kind", default="libretro")
    p.add_argument("--license", default="")
    p.add_argument("--license-name", default="")
    p.add_argument("--source", default="")
    p.add_argument("--sub", default="")
    p.add_argument("--ext-system", action="append", help="ext:system, e.g. fds:nes")
    p.add_argument("--set", action="append", help="another manifest line, key=value")
    p.add_argument("--extra", action="append", help="another file, path::name in the zip")
    p.add_argument("--lib-name", help="the library's name in the zip (default lib/arm64-v8a/<its name>)")
    a = p.parse_args()
    _, line = pack(a)
    print(line)


if __name__ == "__main__":
    main()
