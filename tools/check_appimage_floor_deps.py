#!/usr/bin/env python3
"""Verify the AppImage only uses symbols the Ubuntu 22.04 floor provides.

The AppImage delegates fontconfig, freetype, harfbuzz, alsa and the rest of
the base system stack to the host, so at runtime those libraries are whatever
the target system ships.  Compiling against newer vcpkg headers can introduce
references that the floor libraries do not provide, which would crash at
startup (missing symbol) or at first call (wrong symbol version).  This check
walks every ELF the AppImage ships, collects the undefined symbols with their
version tags, resolves the dynamic-linking closure (the AppImage's own
libraries plus the system libraries of the build host, which is Ubuntu 22.04
in CI), and fails on any symbol or symbol version that nothing present can
satisfy.

Behaviour beyond the symbol level is covered separately by running the
AppImage on the same 22.04 runner (the existing smoke test) and by the test
suite, which executes against the built binary on that floor.

Usage:
  check_appimage_floor_deps.py <mixxx-binary> <buildenv-lib-dir>
"""

import collections
import os
import re
import shutil
import subprocess
import sys


def dynsyms(path):
    """Return (undefined, defined) as {name: set(versions)}; None = unversioned."""
    out = subprocess.run(
        ["readelf", "--dyn-syms", "-W", path],
        capture_output=True,
        text=True,
        check=False,
    ).stdout
    undefined = collections.defaultdict(set)
    defined = collections.defaultdict(set)
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 8:
            continue
        if parts[6] != "UND":  # Ndx column
            continue
        raw = parts[7]
        # Name[@VERSION][@@VERSION]
        name, _, version = raw.partition("@")
        version = version or None
        if name:
            undefined[name].add(version)
    # Defined symbols from a second pass are collected from the same table;
    # entries with Ndx != UND are the definitions.
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 8:
            continue
        if parts[6] == "UND":
            continue
        raw = parts[7]
        if not raw or raw.startswith("."):
            continue
        name, _, version = raw.partition("@")
        version = version or None
        defined[name].add(version)
    return undefined, defined


def needed_sonames(path):
    out = subprocess.run(
        ["readelf", "-d", "-W", path], capture_output=True, text=True, check=False
    ).stdout
    result = set()
    for line in out.splitlines():
        m = re.search(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", line)
        if m:
            result.add(m.group(1))
    return result


def is_elf(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False


def ldconfig_map():
    """soname -> path, from the host's dynamic linker cache."""
    ldconfig = shutil.which("ldconfig")
    if ldconfig is None:
        for cand in ("/sbin/ldconfig", "/usr/sbin/ldconfig"):
            if os.path.isfile(cand):
                ldconfig = cand
                break
    if ldconfig is None:
        return {}
    out = subprocess.run(
        [ldconfig, "-p"], capture_output=True, text=True, check=False
    ).stdout
    mapping = {}
    for line in out.splitlines():
        if "=>" not in line:
            continue
        parts = line.split()
        if len(parts) >= 2:
            mapping[parts[0]] = parts[-1]
    return mapping


_SYSTEM_SEARCH_ROOTS = ("/lib", "/usr/lib")


def find_system_soname(soname, sysmap):
    """Resolve a soname from the host system, via the cache or a file scan."""
    if soname in sysmap:
        return sysmap[soname]
    for base in _SYSTEM_SEARCH_ROOTS:
        if not os.path.isdir(base):
            continue
        for root, _dirs, files in os.walk(base):
            for entry in files:
                if entry == soname or entry.startswith(soname + "."):
                    path = os.path.join(root, entry)
                    if is_elf(path):
                        return path
    return None


def find_in_dir(soname, libdir):
    """Find a soname (or its symlink target) in libdir."""
    for candidate in (
        os.path.join(libdir, soname),
        os.path.join(libdir, soname + ".0"),
    ):
        if os.path.isfile(candidate):
            return candidate
    # fall back to any matching .so* in the directory
    for entry in os.listdir(libdir):
        if entry == soname or entry.startswith(soname + "."):
            full = os.path.join(libdir, entry)
            if is_elf(full):
                return full
    return None


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    binary = sys.argv[1]
    libdir = sys.argv[2]
    if not os.path.isfile(binary):
        print(f"ERROR: binary not found: {binary}", file=sys.stderr)
        return 2
    if not os.path.isdir(libdir):
        print(f"ERROR: buildenv lib dir not found: {libdir}", file=sys.stderr)
        return 2

    sysmap = ldconfig_map()

    # Dynamic-linking closure: start from the binary, follow DT_NEEDED.
    worklist = [binary]
    processed = set()
    undef = collections.defaultdict(set)  # name -> set(versions)
    resolvable = collections.defaultdict(set)  # name -> set(versions)
    missing_libs = []

    while worklist:
        elf = worklist.pop()
        if elf in processed:
            continue
        processed.add(elf)

        u, d = dynsyms(elf)
        for name, versions in u.items():
            undef[name].update(versions)
        for name, versions in d.items():
            resolvable[name].update(versions)

        for soname in needed_sonames(elf):
            # resolve the soname: buildenv lib dir first, then the host system
            path = find_in_dir(soname, libdir)
            if path is None:
                path = find_system_soname(soname, sysmap)
            if path is None or not os.path.isfile(path):
                missing_libs.append(soname)
                continue
            worklist.append(path)

    # Symbol-version aware resolution.
    unresolved = []
    for name in sorted(undef):
        wanted = undef[name]
        have = resolvable.get(name)
        if not have:
            unresolved.append((name, "any"))
            continue
        # An unversioned reference needs the name at all; a versioned one
        # needs the exact version.
        if None in wanted:
            continue  # the name exists, any version satisfies an unversioned ref
        for ver in wanted:
            if ver is not None and ver not in have:
                unresolved.append((name, ver))

    print(f"ELFs walked: {len(processed)}")
    print(f"Undefined symbols: {sum(len(v) or 1 for v in undef.values())}")
    print(f"Missing system libs: {len(missing_libs)}")
    for lib in sorted(set(missing_libs)):
        print(f"  MISSING LIB: {lib}")

    if unresolved:
        print("\nUNRESOLVED on the Ubuntu 22.04 floor:")
        for name, ver in unresolved[:50]:
            print(f"  {name}@{ver}")
        print(f"\nFAIL: {len(unresolved)} symbol(s) not satisfiable by the floor.")
        return 1

    if missing_libs:
        print("\nWARNING: needed libraries absent from the build host (would "
              "be delegated at runtime).")
    print("OK: every referenced symbol is satisfiable by the floor.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
