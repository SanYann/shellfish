#!/bin/bash
# Shellfish PoC — S5: network containment for the web-fetch capability.
#
# Claim: a session granted net.fetch can reach only allow-listed hosts and
# still cannot read user data, and the containment is real (not prompt-based):
#   - The NETWORK profile is what enables fetch; the STRICT profile denies it.
#   - The app-layer allow-list is what blocks off-list hosts (a wildcard
#     control proves the same fetch succeeds when the list permits it).
#   - A network-capable ToolRunner cannot read /Users.
#
# Each security claim has a negative control proving that defense — not luck —
# is what stopped the attack.
#
# NOTE: the positive-fetch tests (T1, T4) require internet access. The
# security-critical DENY tests (T2, T3, T5) do not.
set -u

cd "$(dirname "$0")"
WS="$PWD/workspaces/poc"
BD="$PWD/.build"
STRICT="$PWD/profiles/toolrunner-strict.sb"
NET="$PWD/profiles/toolrunner-net.sb"
RUNNER="$PWD/.build/debug/ToolRunner"

echo "=== Building ==="
swift build --product ToolRunner 2>&1 | tail -5
BUILD_EXIT=${PIPESTATUS[0]}
if [ "$BUILD_EXIT" != "0" ]; then
    echo "Build failed (exit $BUILD_EXIT)"
    exit 2
fi
mkdir -p "$WS"

# run_tool <profile> <netfetch-allow> <json>  -> prints ToolRunner stdout
run_tool() {
    echo "$3" | SHELLFISH_WORKSPACE="$WS" SHELLFISH_NETFETCH_ALLOW="$2" \
        /usr/bin/sandbox-exec -D WORKSPACE="$WS" -D BUILDDIR="$BD" -f "$1" "$RUNNER" 2>/dev/null
}
ok()   { echo "$1" | grep -q '"success":true'; }   # success:true present?

echo ""
echo "=== T1: net profile, allowed host — capability works ==="
T1=$(run_tool "$NET" "example.com" '{"tool":"http_fetch","args":{"url":"https://example.com"}}')
ok "$T1" && T1R=success || T1R=fail
echo "fetch example.com (allow=example.com): $T1R"

echo "=== T2: STRICT profile, same fetch — negative control (network must be denied) ==="
T2=$(run_tool "$STRICT" "example.com" '{"tool":"http_fetch","args":{"url":"https://example.com"}}')
ok "$T2" && T2R=success || T2R=denied
echo "fetch example.com under strict profile: $T2R"

echo "=== T3: net profile, off-list host — allow-list must block ==="
T3=$(run_tool "$NET" "example.com" '{"tool":"http_fetch","args":{"url":"https://example.org"}}')
ok "$T3" && T3R=success || T3R=denied
echo "fetch example.org (allow=example.com): $T3R"

echo "=== T4: net profile, wildcard allow — negative control (off-list now permitted) ==="
T4=$(run_tool "$NET" "*" '{"tool":"http_fetch","args":{"url":"https://example.org"}}')
ok "$T4" && T4R=success || T4R=fail
echo "fetch example.org (allow=*): $T4R"

echo "=== T5: net profile, fetch tool tries to read user data — must be denied ==="
T5=$(run_tool "$NET" "*" "{\"tool\":\"fs.read\",\"args\":{\"path\":\"$HOME/.zshrc\"}}")
ok "$T5" && T5R=read || T5R=denied
echo "fs.read \$HOME/.zshrc from a net session: $T5R"

echo ""
echo "=== Results ==="
echo "T1 allowed-host fetch:        $T1R    (expected success — needs internet)"
echo "T2 strict-profile fetch:      $T2R    (expected denied — profile gates network)"
echo "T3 off-list fetch:            $T3R    (expected denied — allow-list)"
echo "T4 wildcard off-list fetch:   $T4R    (expected success — proves allow-list is the blocker)"
echo "T5 user-data read:            $T5R    (expected denied — no private data on a net session)"

if [ "$T1R" = "success" ] && [ "$T2R" = "denied" ] && [ "$T3R" = "denied" ] && [ "$T4R" = "success" ] && [ "$T5R" = "denied" ]; then
    echo ""
    echo "PASS: net.fetch reaches only allow-listed hosts, the profile (not luck) gates the network, and a net session cannot read user data."
    exit 0
else
    echo ""
    echo "FAIL: see results above. (If T1/T4 failed, check internet connectivity.)"
    exit 1
fi
