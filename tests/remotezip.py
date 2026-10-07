#!/usr/bin/env python3
"""Inspect a remote zip via HTTP range requests (central directory + selected small entries only)."""
import sys, struct, zlib, urllib.request
def rng(url, start, end):
    r = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
    return urllib.request.urlopen(r).read()
def size(url):
    r = urllib.request.Request(url, method="HEAD"); return int(urllib.request.urlopen(r).headers["Content-Length"])
def entries(url):
    n = size(url); tail = rng(url, max(0, n-65557), n-1); i = tail.rfind(b"PK\x05\x06")
    cd_size, cd_off = struct.unpack("<II", tail[i+12:i+20]); cd = rng(url, cd_off, cd_off+cd_size-1)
    p = 0; out = []
    while p < len(cd) and cd[p:p+4] == b"PK\x01\x02":
        meth, = struct.unpack("<H", cd[p+10:p+12]); crc, csz, usz = struct.unpack("<III", cd[p+16:p+28])
        nl, el, cl = struct.unpack("<HHH", cd[p+28:p+34]); lho, = struct.unpack("<I", cd[p+42:p+46])
        name = cd[p+46:p+46+nl].decode(); out.append(dict(name=name, meth=meth, crc=crc, csz=csz, usz=usz, lho=lho))
        p += 46+nl+el+cl
    return n, out
def read(url, e):
    h = rng(url, e["lho"], e["lho"]+29); nl, el = struct.unpack("<HH", h[26:30]); s = e["lho"]+30+nl+el
    d = rng(url, s, s+e["csz"]-1); return d if e["meth"] == 0 else zlib.decompress(d, -15)
if __name__ == "__main__":
    url = sys.argv[1]; n, es = entries(url); print(f"# {url} size={n} entries={len(es)}")
    want = sys.argv[2:]
    for e in es:
        if not want: print(f"{e['usz']:>10} {e['crc']:08x} {e['name']}")
        if e["name"] in want:
            if e["name"].endswith(".jar"):
                import io, zipfile
                print(f"== {e['name']} ({e['csz']} bytes)")
                z = zipfile.ZipFile(io.BytesIO(read(url, e)))
                for nm in ("org/apache/catalina/util/ServerInfo.properties",):
                    if nm in z.namelist(): print(z.read(nm).decode())
            else:
                print(f"== {e['name']}"); print(read(url, e).decode(errors="replace"))
