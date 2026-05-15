#!/usr/bin/env python3
#
# clear-execstack.py — clear the executable-stack flag from ELF files.
#
# GoldSrc binaries (engine_i486.so, cs.so, ...) carry a PT_GNU_STACK segment
# marked executable — a leftover from hand-written assembly objects that lack
# a .note.GNU-stack section. Modern loaders (glibc on Debian 13+) refuse to
# dlopen such objects:
#   "cannot enable executable stack as shared object requires: Invalid argument"
#
# This walks a directory and clears the PF_X bit on every ELF's PT_GNU_STACK
# program header. The stack code is not actually executed, so this is safe and
# is the community-standard fix (equivalent to `execstack -c`).
#
# Usage: clear-execstack.py <directory>
#
import os
import struct
import sys

PT_GNU_STACK = 0x6474E551
PF_X = 0x1


def clear_file(path: str) -> bool:
    """Clear PF_X on PT_GNU_STACK in one ELF file. Returns True if changed."""
    with open(path, "r+b") as f:
        ident = f.read(16)
        if len(ident) < 16 or ident[:4] != b"\x7fELF":
            return False
        is64 = ident[4] == 2
        endian = "<" if ident[5] == 1 else ">"

        if is64:
            f.seek(32); e_phoff = struct.unpack(endian + "Q", f.read(8))[0]
            f.seek(54); e_phentsize = struct.unpack(endian + "H", f.read(2))[0]
            e_phnum = struct.unpack(endian + "H", f.read(2))[0]
            flags_off = 4    # p_flags follows p_type in Elf64_Phdr
        else:
            f.seek(28); e_phoff = struct.unpack(endian + "I", f.read(4))[0]
            f.seek(42); e_phentsize = struct.unpack(endian + "H", f.read(2))[0]
            e_phnum = struct.unpack(endian + "H", f.read(2))[0]
            flags_off = 24   # p_flags offset in Elf32_Phdr

        changed = False
        for i in range(e_phnum):
            phdr = e_phoff + i * e_phentsize
            f.seek(phdr)
            p_type = struct.unpack(endian + "I", f.read(4))[0]
            if p_type != PT_GNU_STACK:
                continue
            f.seek(phdr + flags_off)
            p_flags = struct.unpack(endian + "I", f.read(4))[0]
            if p_flags & PF_X:
                f.seek(phdr + flags_off)
                f.write(struct.pack(endian + "I", p_flags & ~PF_X))
                changed = True
        return changed


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: clear-execstack.py <directory>", file=sys.stderr)
        return 2
    root = sys.argv[1]
    count = 0
    for dirpath, _, files in os.walk(root):
        for name in files:
            path = os.path.join(dirpath, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            try:
                if clear_file(path):
                    count += 1
                    print(f"  cleared exec-stack: {os.path.relpath(path, root)}")
            except Exception:
                pass  # not an ELF / unreadable — skip
    print(f">>> executable-stack flag cleared on {count} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
