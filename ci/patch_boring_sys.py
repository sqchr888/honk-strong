#!/usr/bin/env python3
"""Apply the local macOS-cross ar/ranlib fix to boring-sys, idempotently.

On macOS, CMake picks /usr/bin/ar, which writes BSD/Mach-O archives. ld.lld
cross-linking to aarch64-linux-musl cannot read them, surfacing as undefined
SSL_* / X25519_* / MLKEM_* symbols. The patch forces zig's GNU-format tools.
The block is marked so it can be removed with one edit to restore upstream.
"""
import os
import sys

CI = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(CI, ".."))
BORING = "/Users/chen/tools/cargo/git/checkouts/boring-sys-3c23892426d61c2d/3beb573/build/main.rs"
MARKER = "// HONK-CROSS BEGIN"
LEGACY_MARKER = "// ADZERO-CROSS BEGIN"  # accepted for idempotency on already-patched trees

BLOCK = '''
    // HONK-CROSS BEGIN: on macOS, CMake picks /usr/bin/ar, which writes
    // BSD/Mach-O archives that ld.lld cannot read for the aarch64-linux-musl
    // target. Force zig's GNU-format archiver. Remove this block to restore
    // the upstream build.
    boringssl_cmake
        .define("CMAKE_AR", "{ci}/zigar")
        .define("CMAKE_RANLIB", "{ci}/zigranlib");
    // HONK-CROSS END
'''.format(ci=CI)


def main():
    if not os.path.isfile(BORING):
        print("boring-sys source not found: " + BORING, file=sys.stderr)
        return 1
    with open(BORING, encoding="utf-8") as handle:
        source = handle.read()
    if MARKER in source or LEGACY_MARKER in source:
        print("boring-sys patch already applied")
        return 0
    anchor = "    let mut boringssl_cmake = cmake::Config::new(src_path);\n"
    if anchor not in source:
        print("unexpected boring-sys build/main.rs layout", file=sys.stderr)
        return 2
    source = source.replace(anchor, anchor + BLOCK, 1)
    with open(BORING, "w", encoding="utf-8") as handle:
        handle.write(source)
    print("boring-sys patch applied")
    return 0


if __name__ == "__main__":
    sys.exit(main())
