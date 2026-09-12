#!/usr/bin/env python3
"""Package the two-string XML localization overrides as LSPK v18.

Format reference: https://github.com/Norbyte/lslib/blob/master/LSLib/LS/PackageFormat.cs
No game assets or third-party Python packages are needed. Data entries are stored
uncompressed; the mandatory LZ4 file table uses a standards-compliant literal block.
"""
import argparse
import hashlib
import struct
import xml.etree.ElementTree as ET
from pathlib import Path


def lz4_literals(data):
    size = len(data)
    out = bytearray([min(size, 15) << 4])
    if size >= 15:
        size -= 15
        while size >= 255:
            out.append(255)
            size -= 255
        out.append(size)
    return bytes(out) + data


def build(source, destination):
    files = {"Mods/BG3MetalFX/meta.lsx": (source / "meta.lsx").read_bytes()}
    for xml in sorted((source / "Localization").glob("*/*.xml")):
        entries = ET.parse(xml).getroot().findall("content")
        assert len(entries) == 2 and all(e.attrib.get("version") == "2" for e in entries)
        files[f"Mods/BG3MetalFX/Localization/{xml.parent.name}/{xml.name}"] = xml.read_bytes()
    assert len(files) == 16, "Expected meta.lsx and 15 localizations"
    payload, table = bytearray(40), bytearray()
    digest = hashlib.md5()
    for name, content in sorted(files.items()):
        offset = len(payload)
        payload.extend(content)
        digest.update(content)
        table.extend(struct.pack("<256sIHBBII", name.encode(), offset, 0, 0, 0, len(content), 0))
        payload.extend(b"\0" * ((-(len(payload) - 40)) % 64))
    offset = len(payload)
    compressed = lz4_literals(table)
    payload.extend(struct.pack("<II", len(files), len(compressed)) + compressed)
    md5 = bytes((b + 1) & 255 for b in digest.digest())
    payload[:40] = struct.pack("<4sIQIBB16sH", b"LSPK", 18, offset, len(compressed) + 8, 0, 0, md5, 1)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(payload)
    print(f"MOD_BUILD PASS: {destination} ({len(files)} entries, {len(payload)} bytes)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    build(args.source, args.destination)
