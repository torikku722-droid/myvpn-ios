#!/usr/bin/env python3
"""CI-time release configuration (run from repo root before xcodebuild).

Env: BUNDLE_PREFIX, TEAM_ID, APP_PROFILE, EXT_PROFILE, VERSION (default 1.0.0), BUILD (default 1)
"""
import os, re, sys, pathlib

prefix = os.environ["BUNDLE_PREFIX"]
team = os.environ["TEAM_ID"]
app_profile = os.environ["APP_PROFILE"]
ext_profile = os.environ["EXT_PROFILE"]
version = os.environ.get("VERSION", "1.0.0")
build = os.environ.get("BUILD", "1")

path = pathlib.Path("sing-box.xcodeproj/project.pbxproj")
raw = path.read_bytes().decode("utf-8")
crlf = "\r\n" in raw
t = raw.replace("\r\n", "\n")

# bundle prefix (only identifiers, never file paths)
t, n_bundle = re.subn(r"((?:PRODUCT_BUNDLE_IDENTIFIER|BASE_PACKAGE_IDENTIFIER) = )io\.nekohasekai\.sfavt", r"\g<1>" + prefix, t)
# team
t, n_team = re.subn(r"DEVELOPMENT_TEAM = 287TTNZF8L;", "DEVELOPMENT_TEAM = %s;" % team, t)
t, n_team2 = re.subn(r'("DEVELOPMENT_TEAM\[sdk=macosx\*\]" = )287TTNZF8L;', r"\g<1>%s;" % team, t)
# versions must match between app and extension
t, n_ver = re.subn(r"MARKETING_VERSION = [^;]+;", "MARKETING_VERSION = %s;" % version, t)
t, n_build = re.subn(r"CURRENT_PROJECT_VERSION = [^;]+;", "CURRENT_PROJECT_VERSION = %s;" % build, t)

CFG = re.compile(r"(\t\t[0-9A-F]{24} /\* (?:Debug|Release) \*/ = \{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = \{\n)(.*?)(\n\t\t\t\};\n)", re.S)
signed = {"SFI": 0, "Extension": 0}

def sign(m):
    head, body, tail = m.groups()
    if "CODE_SIGN_ENTITLEMENTS = SFI/SFI.entitlements;" in body:
        key, prof = "SFI", app_profile
    elif "CODE_SIGN_ENTITLEMENTS = Extension/Extension.entitlements;" in body:
        key, prof = "Extension", ext_profile
    else:
        return m.group(0)
    body = re.sub(r"\t\t\t\tCODE_SIGN_STYLE = [^;]+;", "\t\t\t\tCODE_SIGN_STYLE = Manual;", body)
    if re.search(r"\t\t\t\tCODE_SIGN_IDENTITY = ", body):
        body = re.sub(r'\t\t\t\tCODE_SIGN_IDENTITY = [^;]+;', '\t\t\t\tCODE_SIGN_IDENTITY = "Apple Distribution";', body)
    else:
        body = re.sub(r"(\t\t\t\tCODE_SIGN_ENTITLEMENTS = [^;]+;)", r'\1\n\t\t\t\tCODE_SIGN_IDENTITY = "Apple Distribution";', body)
    body = re.sub(r'\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = [^;]*;', '\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = "%s";' % prof, body)
    signed[key] += 1
    return head + body + tail

t = CFG.sub(sign, t)

print("bundle ids: %d, team: %d(+%d), versions: %d, builds: %d" % (n_bundle, n_team, n_team2, n_ver, n_build))
print("signing configs set:", signed)
if signed["SFI"] < 2 or signed["Extension"] < 2 or n_bundle == 0:
    sys.exit("unexpected project layout, refusing to continue")
path.write_bytes((t.replace("\n", "\r\n") if crlf else t).encode("utf-8"))
