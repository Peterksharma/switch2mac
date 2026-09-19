#!/bin/bash
# check-profile.sh — verify a Developer ID provisioning profile really carries
# the HID virtual-device entitlement before we sign with it.
#
# A profile that is expired, built for the wrong App ID, or missing the
# entitlement still signs without complaint — macOS only rejects it later, by
# killing the app at launch. So check here, loudly, instead.
#
# Usage: ./scripts/check-profile.sh [path/to.provisionprofile]
#        (default: signing/FinallyTheControllerWorks.provisionprofile)

set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-signing/FinallyTheControllerWorks.provisionprofile}"

if [ ! -f "$PROFILE" ]; then
    echo "error: no provisioning profile at $PROFILE" >&2
    echo "       Download one from developer.apple.com (Profiles → Developer ID)" >&2
    exit 1
fi

DECODED=$(mktemp -t ftcw-profile)
trap 'rm -f "$DECODED"' EXIT

if ! security cms -D -i "$PROFILE" > "$DECODED" 2>/dev/null; then
    echo "error: $PROFILE is not a readable provisioning profile" >&2
    exit 1
fi

# SHA-1 hashes of the code-signing identities in the keychain, so we can tell
# whether the profile was generated against a certificate we actually hold.
INSTALLED_HASHES=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/^ *[0-9]+\)/ {print $2}' || true)

INSTALLED_HASHES="$INSTALLED_HASHES" /usr/bin/python3 - "$DECODED" Resources/entitlements-dev.plist "$PROFILE" <<'PY'
import datetime, hashlib, os, plistlib, sys

decoded, wanted_path, profile_path = sys.argv[1], sys.argv[2], sys.argv[3]
HID = "com.apple.developer.hid.virtual.device"

with open(decoded, "rb") as f:
    profile = plistlib.load(f)
with open(wanted_path, "rb") as f:
    wanted = plistlib.load(f)

ent = profile.get("Entitlements", {})
failures = []

def ok(msg):
    print("  ✓ " + msg)

def bad(msg, fix):
    print("  ✗ " + msg)
    failures.append(fix)

print("Profile: %s" % profile_path)
print("  name:  %s" % profile.get("Name", "?"))
print("  team:  %s" % ", ".join(profile.get("TeamIdentifier", []) or ["?"]))

# 1. The entitlement this whole release is waiting on.
if ent.get(HID) is True:
    ok("carries %s" % HID)
else:
    bad("missing %s" % HID,
        "Enable the HID Virtual Device capability on App ID %s, then "
        "regenerate the profile." % wanted.get("com.apple.application-identifier", "?"))

# 2. App ID and team must match what we sign with, or macOS kills the app.
want_app = wanted.get("com.apple.application-identifier")
got_app = ent.get("com.apple.application-identifier")
if got_app == want_app:
    ok("application-identifier matches: %s" % got_app)
else:
    bad("application-identifier is %s, entitlements-dev.plist expects %s"
        % (got_app, want_app),
        "Regenerate the profile against App ID %s (or fix "
        "Resources/entitlements-dev.plist)." % want_app)

want_team = wanted.get("com.apple.developer.team-identifier")
got_team = ent.get("com.apple.developer.team-identifier")
if got_team == want_team:
    ok("team-identifier matches: %s" % got_team)
else:
    bad("team-identifier is %s, expected %s" % (got_team, want_team),
        "Use a profile from team %s." % want_team)

# 3. Expiry. A stale profile signs fine and fails at launch.
exp = profile.get("ExpirationDate")
if isinstance(exp, datetime.datetime):
    now = datetime.datetime.now(exp.tzinfo) if exp.tzinfo else datetime.datetime.utcnow()
    left = (exp - now).days
    if left > 0:
        ok("expires %s (%d days left)" % (exp.date(), left))
    else:
        bad("expired on %s" % exp.date(), "Download a fresh profile.")
else:
    print("  ? no expiration date in profile")

# 4. Developer ID profiles provision no devices; a Development profile does.
if profile.get("ProvisionedDevices"):
    bad("this is a Development profile (it lists provisioned devices)",
        "Create a Distribution → Developer ID profile instead; a "
        "development profile only runs on registered machines.")
else:
    ok("distribution profile (no device list)")

# 5. The certificate the profile was built against must be one we hold.
installed = set(filter(None, os.environ.get("INSTALLED_HASHES", "").split()))
profile_hashes = {}
for der in profile.get("DeveloperCertificates", []):
    profile_hashes[hashlib.sha1(der).hexdigest().upper()] = der
if not installed:
    print("  ? no code-signing identities in the keychain to compare against")
elif profile_hashes & installed:
    ok("built against a certificate present in this keychain")
else:
    bad("none of the profile's certificates are in this keychain",
        "Install the Developer ID Application certificate (and its private "
        "key) this profile was generated for, or regenerate the profile "
        "against the certificate you hold.")

if failures:
    print("\nNot ready to sign:")
    for i, fix in enumerate(failures, 1):
        print("  %d. %s" % (i, fix))
    sys.exit(1)

print("\nProfile is ready: signing with it yields system-wide virtual gamepads.")
PY
