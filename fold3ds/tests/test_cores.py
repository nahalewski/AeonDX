"""Tests for the .aeoncore format: tools/cores/make_aeoncore.py packs a core,
fold3ds/cores.lua reads its catalogue line, checks its SHA-256 and reads its
manifest.

    python fold3ds/tests/test_cores.py      (needs luajit)
"""
import os
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PASS = FAIL = 0


def check(name, got, want):
    global PASS, FAIL
    if got == want:
        PASS += 1
    else:
        FAIL += 1
        print(f"  FAIL {name}\n       got  {got!r}\n       want {want!r}")


def lua(code):
    script = "love = { filesystem = {} }\npackage.path = %r .. '/?.lua;' .. package.path\n" % ROOT + code
    r = subprocess.run(["luajit", "-e", script], capture_output=True, text=True, timeout=120)
    return r.stdout.strip() if r.returncode == 0 else "LUAERR " + r.stderr.strip()


def main():
    with tempfile.TemporaryDirectory() as d:
        so = os.path.join(d, "fceumm_libretro_android.so")
        open(so, "wb").write(os.urandom(70000))
        lic = os.path.join(d, "COPYING")
        open(lic, "w").write("GPL")
        out = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "cores", "make_aeoncore.py"),
                              "--id", "fceumm", "--name", "FCEUmm", "--systems", "nes",
                              "--extensions", "nes|fds", "--version", "20260926", "--lib", so,
                              "--license", lic, "--license-name", "GPL-2.0", "--source", "https://x",
                              "--sub", "NES games", "--ext-system", "fds:nes", "--out", d],
                             capture_output=True, text=True, check=True).stdout.strip()
        f = out.split("\t")
        check("catalog fields", len(f), 8)
        core = os.path.join(d, "fceumm.aeoncore")
        z = zipfile.ZipFile(core)
        check("zip entries", sorted(z.namelist()),
              ["LICENSE", "aeoncore.txt", "lib/arm64-v8a/fceumm_libretro_android.so"])
        manifest = z.read("aeoncore.txt").decode()
        got = lua("local C = require('fold3ds.cores')\n"
                  "local cat, order = C.parseCatalog(%r)\n"
                  "local c = cat.fceumm\n"
                  "local fh = io.open(%r, 'rb') local b = fh:read('*a') fh:close()\n"
                  "local m = C.parseKV(%r)\n"
                  "print(#order, c.file, c.size == #b, C.sha256(b) == c.sha256, c.systems[1], c.version, m.lib, m.ext_fds, m.format)"
                  % ("# header\n" + out + "\n", core, manifest))
        check("lua reads it", got.split("\t"),
              ["1", "fceumm.aeoncore", "true", "true", "nes", "20260926",
               "lib/arm64-v8a/fceumm_libretro_android.so", "nes", "1"])
    # every line of the cores list has its eight fields
    for line in open(os.path.join(ROOT, "tools", "cores", "cores.tsv")):
        if line.startswith("#") or not line.strip():
            continue
        check("cores.tsv " + line.split("\t")[0], len(line.rstrip("\n").split("\t")), 8)
    print(f"{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
