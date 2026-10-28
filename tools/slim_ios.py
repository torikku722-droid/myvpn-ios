#!/usr/bin/env python3
"""Slim sing-box-for-apple for an iOS-only build (run from repo root).

Touches ONLY the SFI target: drops Widget/Intents/FileProvider extension
dependencies and embed entries, and strips iCloud keys from entitlements.
Other targets stay in the project, but scheme SFI never builds them.
"""
import re, sys, pathlib

PBX = pathlib.Path("sing-box.xcodeproj/project.pbxproj")
DROP = ["WidgetExtension", "IntentsExtension", "FileProviderExtension"]

raw = PBX.read_bytes().decode("utf-8")
crlf = "\r\n" in raw
t = raw.replace("\r\n", "\n")

SFI_RE = re.compile(r"\t\t[0-9A-F]{24} /\* SFI \*/ = \{\n\t\t\tisa = PBXNativeTarget;.*?\n\t\t\};\n", re.S)
m = SFI_RE.search(t)
if not m:
    sys.exit("SFI target not found")
sfi = m.group(0)
new_sfi = sfi

# 1. dependencies of SFI that point at dropped targets
dep_ids = re.findall(r"\t\t\t\t([0-9A-F]{24}) /\* PBXTargetDependency \*/,", sfi)
dropped_deps = []
for d in dep_ids:
    blk = re.search(r"\t\t" + d + r" /\* PBXTargetDependency \*/ = \{.*?\n\t\t\};\n", t, re.S).group(0)
    if any("/* " + n + " */" in blk for n in DROP):
        dropped_deps.append(d)
        new_sfi = new_sfi.replace("\t\t\t\t" + d + " /* PBXTargetDependency */,\n", "")
print("SFI dependencies dropped:", dropped_deps)

# 2. embed phases belonging to SFI
phase_ids = re.findall(r"\t\t\t\t([0-9A-F]{24}) /\* (Embed [^*]*?) \*/,", sfi)
removed = 0
for pid, pname in phase_ids:
    pm = re.search(r"\t\t" + pid + r" /\* " + re.escape(pname) + r" \*/ = \{.*?\n\t\t\};\n", t, re.S)
    blk = pm.group(0)
    nb = blk
    for n in DROP:
        nb, c = re.subn(r"\t\t\t\t[0-9A-F]{24} /\* " + n + r"\.appex in [^*]*\*/,\n", "", nb)
        removed += c
    t = t.replace(blk, nb)
    if "files = (\n\t\t\t);" in nb and "ExtensionKit" in pname:
        new_sfi = new_sfi.replace("\t\t\t\t" + pid + " /* " + pname + " */,\n", "")
        print("removed empty phase from SFI:", pname)
print("SFI embed entries removed:", removed)
t = t.replace(sfi, new_sfi)

PBX.write_bytes((t.replace("\n", "\r\n") if crlf else t).encode("utf-8"))

# 3. iCloud out of entitlements
for p in ["SFI/SFI.entitlements", "Extension/Extension.entitlements"]:
    f = pathlib.Path(p)
    if not f.exists():
        continue
    s = f.read_bytes().decode("utf-8")
    c = "\r\n" in s
    s = s.replace("\r\n", "\n")
    for key in ["com.apple.developer.icloud-container-identifiers",
                "com.apple.developer.icloud-services",
                "com.apple.developer.ubiquity-container-identifiers"]:
        s = re.sub(r"\t<key>" + re.escape(key) + r"</key>\n\t<array>\n(?:\t\t<string>.*?</string>\n)+\t</array>\n", "", s)
    f.write_bytes((s.replace("\n", "\r\n") if c else s).encode("utf-8"))
    print("entitlements cleaned:", p)
print("done")

# 4. ApplicationDelegate: no FileProvider domain (extension removed)
ad = pathlib.Path("SFI/ApplicationDelegate.swift")
if ad.exists():
    s = ad.read_bytes().decode("utf-8")
    c = "\r\n" in s
    s = s.replace("\r\n", "\n")
    s = s.replace("            registerFileProviderDomain()\n", "")
    s = re.sub(r"\n    @available\(iOS 16\.0, \*\)\n    private nonisolated func registerFileProviderDomain\(\) \{.*?\n    \}\n", "\n", s, flags=re.S)
    ad.write_bytes((s.replace("\n", "\r\n") if c else s).encode("utf-8"))
    print("ApplicationDelegate patched")
