import sys,subprocess
b=sys.argv[1]
out=subprocess.run(["otool","-arch","arm64","-s","__TEXT","__entitlements",b],capture_output=True,text=True).stdout
data=bytearray()
for l in out.splitlines()[2:]:
    parts=l.split("\t")
    if len(parts)<2: continue
    for w in parts[1].split():
        data+=bytes.fromhex(w)[::-1]
print(data.decode("utf-8","replace"))
