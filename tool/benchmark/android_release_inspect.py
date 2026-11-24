#!/usr/bin/env python3
"""Verify compiled privacy rules and native 16 KiB loading in split Easy APKs."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import zipfile


ABIS = {"arm64-v8a": (2, 183), "armeabi-v7a": (1, 40), "x86_64": (2, 62)}
PAGE_SIZE = 16 * 1024
BACKUP_DOMAINS = {
    "root", "file", "database", "sharedpref", "external", "device_root",
    "device_file", "device_database", "device_sharedpref",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def output(*command):
    return subprocess.check_output(command, text=True)


def attribute(tree, name):
    matches = re.findall(rf"^\s*A: [^\s]+:{name}\(0x[\da-f]+\)=(\S+)", tree, re.M)
    require(len(matches) == 1, f"Expected one manifest value for {name}.")
    return matches[0]


def resource_xml(aapt, apk, manifest, resource_table, name, reference):
    entry = re.search(
        rf"^\s*resource (0x[\da-f]+) xml/{name}\s*\n"
        rf"\s*\(\) \(file\) (res/[^ \n]+) type=XML$",
        resource_table, re.M,
    )
    require(entry is not None and attribute(manifest, reference) == f"@{entry[1]}",
            f"Manifest did not reference the expected {reference} resource.")
    return output(aapt, "dump", "xmltree", "--file", entry[2], apk)


def verify_privacy(aapt, apk):
    manifest = output(aapt, "dump", "xmltree", "--file", "AndroidManifest.xml", apk)
    for name, value in {"allowBackup": "false", "fullBackupContent": "false",
                        "extractNativeLibs": "false", "minSdkVersion": "24",
                        "targetSdkVersion": "36"}.items():
        require(attribute(manifest, name) == value, f"Unexpected manifest value for {name}.")

    resources = output(aapt, "dump", "resources", apk)
    protection = resource_xml(aapt, apk, manifest, resources, "easy_data_extraction_rules", "dataExtractionRules")
    modes = re.split(r"^\s*E: (cloud-backup|device-transfer) \([^\n]+\)", protection, flags=re.M)
    require(modes[1::2] == ["cloud-backup", "device-transfer"], "Unexpected Android backup modes.")
    for mode, policy in zip(modes[1::2], modes[2::2]):
        exclusions = re.findall(r'A: domain="([a-z_]+)"[^\n]*\n\s*A: path="([^"]+)"', policy)
        require(not re.search(r"E: include\b", policy) and
                len(exclusions) == len(BACKUP_DOMAINS) and
                set(exclusions) == {(domain, ".") for domain in BACKUP_DOMAINS},
                f"Unexpected backup exclusions for {mode}.")

    networks = resource_xml(aapt, apk, manifest, resources, "easy_network_security", "networkSecurityConfig")
    rules = [re.sub(r" \(line=\d+\)$", "", line.strip()) for line in networks.splitlines()]
    require(rules == [
        "E: network-security-config", "E: base-config", "A: cleartextTrafficPermitted=false",
        "E: domain-config", "A: cleartextTrafficPermitted=true",
        "E: domain", "A: includeSubdomains=false", "T: '127.0.0.1'",
        "E: domain", "A: includeSubdomains=false", "T: '::1'",
    ], "The native network policy differs from the exact cleartext loopback allowlist.")


def load_alignments(library, abi, name):
    elf_class, machine = ABIS[abi]
    require(library[:6] == b"\x7fELF" + bytes((elf_class, 1)) and
            struct.unpack_from("<H", library, 18)[0] == machine,
            f"{name} is not the expected ELF for {abi}.")
    if elf_class == 1:
        offset = struct.unpack_from("<I", library, 28)[0]
        entry_size, count = struct.unpack_from("<HH", library, 42)
        entry = struct.Struct("<IIIIIIII")
        location_fields = (1, 2, 7)
    else:
        offset = struct.unpack_from("<Q", library, 32)[0]
        entry_size, count = struct.unpack_from("<HH", library, 54)
        entry = struct.Struct("<IIQQQQQQ")
        location_fields = (2, 3, 7)
    require(entry_size == entry.size and offset + entry_size * count <= len(library),
            f"Invalid ELF program headers in {name}.")
    alignments = []
    for header in entry.iter_unpack(library[offset:offset + entry_size * count]):
        if header[0] != 1:
            continue
        file_offset, virtual_address, alignment = (header[index] for index in location_fields)
        require(alignment >= PAGE_SIZE and alignment & (alignment - 1) == 0 and
                (virtual_address - file_offset) % PAGE_SIZE == 0,
                f"A load segment in {name} is incompatible with 16 KiB pages.")
        alignments.append(alignment)
    require(bool(alignments), f"No load segments in {name}.")
    return sorted(set(alignments))


def verify_package(tools, apk):
    badging = output(tools / "aapt2", "dump", "badging", apk)
    require("package: name='app.launchsites.easy'" in badging and
            "launchable-activity: name='app.launchsites.easy.MainActivity'" in badging,
            "The Easy application ID or launch activity is missing.")
    require(not re.search(r"^application-debuggable(?:\s|$)", badging, re.M),
            "The review package must use a non-debuggable release build.")
    verify_privacy(tools / "aapt2", apk)
    output(tools / "zipalign", "-c", "-P", "16", "4", apk)
    signing = output(tools / "apksigner", "verify", "--verbose", "--print-certs", apk)
    certificate = re.search(r"^Signer #1 certificate SHA-256 digest: ([\da-f]{64})$", signing, re.M)
    require(re.search(r"^Number of signers: 1$", signing, re.M) and
            "CN=Android Debug" in signing and certificate is not None,
            "Expected the development signing certificate for the review package.")

    with zipfile.ZipFile(apk) as archive:
        libs = [entry for entry in archive.infolist()
                if entry.filename.startswith("lib/") and entry.filename.endswith(".so")]
        abis = {entry.filename.split("/")[1] for entry in libs}
        require(len(abis) == 1 and abis.issubset(ABIS), "Expected one supported ABI per APK.")
        abi = abis.pop()
        result = {}
        for library in libs:
            name = Path(library.filename).name
            require(name not in result and library.compress_type == zipfile.ZIP_STORED,
                    f"Duplicate or compressed native library {name}.")
            result[name] = load_alignments(archive.read(library), abi, name)
        require({"libapp.so", "libflutter.so", "libsqlite3.so"}.issubset(result),
                "A required Flutter or workspace library is missing.")

    return abi, {
        "filename": apk.name,
        "bytes": apk.stat().st_size,
        "sha256": hashlib.sha256(apk.read_bytes()).hexdigest(),
        "certificate_sha256": certificate[1],
        "elf_segment_alignments": result,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-tools", type=Path, required=True)
    parser.add_argument("--app-revision", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("apk", nargs=3, type=Path)
    args = parser.parse_args()
    try:
        require(re.fullmatch(r"[0-9a-f]{40}", args.app_revision), "Provide the full app commit hash.")
        result = dict(verify_package(args.build_tools, apk) for apk in args.apk)
        require(set(result) == set(ABIS), "Provide all three split APKs exactly once.")
        require(len({item["certificate_sha256"] for item in result.values()}) == 1,
                "The same development signing certificate must sign all split APKs.")
    except (ValueError, OSError, struct.error, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        parser.exit(1, f"{error}\n")
    args.output.write_text(json.dumps({"app_revision": args.app_revision,
                                      "inspector_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                                      "development_signed": True, "debuggable": False, "packages": result},
                                     indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
