#!/usr/bin/env python3
"""One-time branding for the iOS app (run from repo root, then commit).

- display name -> "Хорёк VPN"
- adds URL scheme horekvpn:// (sing-box:// stays working)
- removes leftover iCloud container block from SFI/Info.plist
- replaces local-network usage text
"""
import re, sys, pathlib

NAME = "Хорёк VPN"

def read(p):
    raw = pathlib.Path(p).read_bytes().decode("utf-8")
    return raw.replace("\r\n", "\n"), "\r\n" in raw

def write(p, text, crlf):
    pathlib.Path(p).write_bytes((text.replace("\n", "\r\n") if crlf else text).encode("utf-8"))

# --- Info.plist
p = "SFI/Info.plist"
s, c = read(p)
s, n1 = re.subn(r"\t<key>NSUbiquitousContainers</key>\n\t<dict>\n.*?\n\t</dict>\n", "", s, flags=re.S)
s, n2 = re.subn(r"(<key>CFBundleURLSchemes</key>\n\t\t\t<array>\n\t\t\t\t<string>sing-box</string>\n)",
                r"\1\t\t\t\t<string>horekvpn</string>\n", s)
s, n3 = re.subn(r"(<key>NSLocalNetworkUsageDescription</key>\n\t<string>).*?(</string>)",
                r"\1Приложению нужен доступ к локальной сети, чтобы корректно настроить маршрутизацию VPN.\2", s)
write(p, s, c)
print("Info.plist: iCloud block removed=%d, url scheme added=%d, local network text=%d" % (n1, n2, n3))

# --- display name in project
p = "sing-box.xcodeproj/project.pbxproj"
s, c = read(p)
s, n = re.subn(r'(INFOPLIST_KEY_CFBundleDisplayName = )"sing-box";', r'\1"%s";' % NAME, s)
write(p, s, c)
print("display name replaced in %d build configs" % n)
if n == 0:
    sys.exit("display name not found")
