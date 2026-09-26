reqs = ["aes_kek_generation_source", "aes_key_generation_source", "master_key_00", "master_key_12"]
found = {}
keyfile = r"C:\Pokemon Legends - Z-A\user\keys\prod.keys"
try:
    with open(keyfile, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k = line.split("=")[0].strip()
                if k in reqs:
                    found[k] = True
    for k in reqs:
        print(f"{k}: {'PRESENT' if found.get(k) else 'MISSING'}")
except Exception as e:
    print("Error opening file:", e)
