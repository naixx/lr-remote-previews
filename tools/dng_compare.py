"""Compare two DNG files: tags of IFD0 and of the raw image IFD, the compressed image tiles, the XMP packet.

Usage:
    python tools/dng_compare.py <a.dng> <b.dng> [--all]

Made to check that a smart preview built by the server (Adobe DNG Converter with `-lossy -side 2560 -p0`) is the same
thing as the one Lightroom Classic builds itself from the same raw file, and to repeat that check after an update of
either program. Prints only the tags that differ (`--all` prints every tag of A first) and how many image tiles are
byte-identical. Read-only. Classic TIFF only (not BigTIFF); the first SubIFD is taken as the raw image.

Standard library only.
"""
import difflib
import struct
import sys

NAMES = {
    0x00FE: "NewSubFileType", 0x0100: "Width", 0x0101: "Height", 0x0102: "BitsPerSample", 0x0103: "Compression",
    0x0106: "Photometric", 0x010F: "Make", 0x0110: "Model", 0x0111: "StripOffsets", 0x0112: "Orientation",
    0x0115: "SamplesPerPixel", 0x0117: "StripByteCounts", 0x0131: "Software", 0x0132: "DateTime",
    0x0142: "TileWidth", 0x0143: "TileLength", 0x0144: "TileOffsets", 0x0145: "TileByteCounts", 0x014A: "SubIFDs",
    0x02BC: "XMP", 0x8769: "ExifIFD", 0x8825: "GPSIFD", 0xC612: "DNGVersion", 0xC613: "DNGBackwardVersion",
    0xC614: "UniqueCameraModel", 0xC61A: "BlackLevel", 0xC61D: "WhiteLevel", 0xC620: "DefaultCropSize",
    0xC621: "ColorMatrix1", 0xC622: "ColorMatrix2", 0xC628: "AsShotNeutral", 0xC62A: "BaselineExposure",
    0xC630: "LensInfo", 0xC634: "DNGPrivateData", 0xC65D: "RawDataUniqueID", 0xC68B: "OriginalRawFileName",
    0xC6F8: "ProfileName", 0xC6FA: "ProfileHueSatMapData1", 0xC6FB: "ProfileHueSatMapData2",
    0xC716: "PreviewApplicationName", 0xC717: "PreviewApplicationVersion", 0xC719: "PreviewSettingsDigest",
    0xC71B: "PreviewDateTime", 0xC726: "ProfileLookTableData", 0xC740: "OpcodeList1", 0xC741: "OpcodeList2",
    0xC74E: "OpcodeList3", 0xC761: "NoiseProfile", 0xC791: "OriginalDefaultFinalSize",
    0xC792: "OriginalBestQualityFinalSize", 0xC793: "OriginalDefaultCropSize", 0xC7A7: "NewRawImageDigest",
    0xCD49: "JXLDistance", 0xCD4A: "JXLEffort", 0xCD4B: "JXLDecodeSpeed",
}
SIZES = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4}
FMT = {1: "B", 3: "H", 4: "I", 6: "b", 8: "h", 9: "i", 11: "f", 12: "d", 13: "I"}
POINTERS = {0x0111, 0x0144, 0x014A, 0x8769, 0x8825}  # file offsets: differ whenever anything before them does


def load(path):
    with open(path, "rb") as f:
        data = f.read()
    bo = "<" if data[:2] == b"II" else ">"

    def ifd(off):
        (n,) = struct.unpack_from(bo + "H", data, off)
        out = {}
        for i in range(n):
            tag, typ, cnt, val = struct.unpack_from(bo + "HHI4s", data, off + 2 + i * 12)
            size = SIZES.get(typ, 1) * cnt
            raw = val[:size] if size <= 4 else data[struct.unpack(bo + "I", val)[0]:][:size]
            out[tag] = (typ, cnt, raw)
        return out

    def numbers(entry):
        typ, cnt, raw = entry
        return list(struct.unpack(bo + FMT[typ] * cnt, raw))

    top = ifd(struct.unpack_from(bo + "I", data, 4)[0])
    sub, tiles = {}, []
    if 0x014A in top:
        sub = ifd(numbers(top[0x014A])[0])
        if 0x0144 in sub:
            tiles = [data[o:o + n] for o, n in zip(numbers(sub[0x0144]), numbers(sub[0x0145]))]
    xmp = top[0x02BC][2].decode("utf8", "replace").splitlines() if 0x02BC in top else []
    return {"bo": bo, "IFD0": top, "raw": sub, "tiles": tiles, "xmp": xmp, "size": len(data)}


def rationals(bo, entry):
    typ, cnt, raw = entry
    v = struct.unpack(bo + ("II" if typ == 5 else "ii") * cnt, raw)
    return [v[i] / v[i + 1] if v[i + 1] else float("nan") for i in range(0, len(v), 2)]


def same_value(a, b, x, y):
    """True if two entries hold the same value; rationals may be written with different denominators."""
    if x is None or y is None:
        return x is y
    if x == y and a["bo"] == b["bo"]:
        return True
    if x[0] in (5, 10) and x[:2] == y[:2]:
        return rationals(a["bo"], x) == rationals(b["bo"], y)
    return False


def show(bo, entry):
    if entry is None:
        return "(absent)"
    typ, cnt, raw = entry
    if typ == 2:
        return repr(raw.split(b"\0")[0].decode("latin1"))
    if typ in (5, 10):
        return " ".join("%g" % x for x in rationals(bo, entry)[:12])
    if typ in FMT and cnt <= 16:
        return " ".join("%g" % x if typ in (11, 12) else str(x) for x in struct.unpack(bo + FMT[typ] * cnt, raw))
    return "[%d bytes]" % len(raw)


def main():
    paths = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(paths) != 2:
        sys.exit(__doc__)
    a, b = load(paths[0]), load(paths[1])
    out = ["A: %s (%d bytes)" % (paths[0], a["size"]), "B: %s (%d bytes)" % (paths[1], b["size"])]
    if "--all" in sys.argv:
        for part in ("IFD0", "raw"):
            for tag, entry in sorted(a[part].items()):
                out.append("  A %-4s %04X %-28s %s" % (part, tag, NAMES.get(tag, "?"), show(a["bo"], entry)))
    for part in ("IFD0", "raw"):
        tags = sorted(set(a[part]) | set(b[part]))
        differ = [t for t in tags if t not in POINTERS and not same_value(a, b, a[part].get(t), b[part].get(t))]
        out.append("%s: %d tags in A, %d in B, %d differ" % (part, len(a[part]), len(b[part]), len(differ)))
        for t in differ:
            out.append("  %04X %-26s A: %s" % (t, NAMES.get(t, "?"), show(a["bo"], a[part].get(t))))
            out.append("  %4s %-26s B: %s" % ("", "", show(b["bo"], b[part].get(t))))
    same = sum(1 for x, y in zip(a["tiles"], b["tiles"]) if x == y)
    out.append("image tiles: %d in A (%d bytes), %d in B (%d bytes), byte-identical: %d" % (
        len(a["tiles"]), sum(map(len, a["tiles"])), len(b["tiles"]), sum(map(len, b["tiles"])), same))
    for i, (x, y) in enumerate(zip(a["tiles"], b["tiles"])):
        if x != y:
            n = sum(1 for p, q in zip(x, y) if p != q) + abs(len(x) - len(y))
            out.append("  tile %d: %d and %d bytes, %d bytes differ" % (i, len(x), len(y), n))
    diff = list(difflib.unified_diff(a["xmp"], b["xmp"], "A", "B", n=0, lineterm=""))
    out.append("XMP: %d lines in A, %d in B, %d changed" % (
        len(a["xmp"]), len(b["xmp"]), sum(1 for l in diff if l.startswith("+") and not l.startswith("+++"))))
    out += ["  " + l.strip() for l in diff if l[:1] in "+-" and l[:3] not in ("+++", "---")]
    sys.stdout.buffer.write(("\n".join(out) + "\n").encode("utf8"))


if __name__ == "__main__":
    main()
