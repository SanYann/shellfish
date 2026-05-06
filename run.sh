#!/bin/bash
# Shellfish PoC — S1 test runner.
# PASS = the sandbox denied the exfil attempt.
# FAIL = data reached the attacker observer OR the tool call succeeded.
set -u

cd "$(dirname "$0")"

PROFILE="${SHELLFISH_PROFILE:-$(pwd)/profiles/toolrunner.sb}"
WORKSPACE="$(pwd)/workspaces/poc"
OBSERVER_LOG=/tmp/shellfish-poc-observer.log

mkdir -p "$WORKSPACE"
echo "harmless decoy content" > "$WORKSPACE/decoy.txt"

# Build (idempotent if already built).
echo "=== Building ==="
swift build 2>&1 | tail -20
BUILD_EXIT=${PIPESTATUS[0]}
if [ "$BUILD_EXIT" != "0" ]; then
    echo "Build failed (exit $BUILD_EXIT)"
    exit 2
fi

# Start the attacker observer in the background.
echo ""
echo "=== Starting AttackerObserver on 127.0.0.1:9999 ==="
: > "$OBSERVER_LOG"
.build/debug/AttackerObserver &
OBSERVER_PID=$!
# Give it a moment to bind.
sleep 1

# Cleanup on exit.
trap "kill $OBSERVER_PID 2>/dev/null; wait $OBSERVER_PID 2>/dev/null" EXIT

# Sanity check: observer is reachable from outside the sandbox.
echo ""
echo "=== Sanity check: observer reachable without sandbox ==="
SANITY=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:9999/sanity?check=1" || echo "FAIL")
echo "Direct curl HTTP code: $SANITY (expected 200)"

# Run the harness.
echo ""
echo "=== Running Harness (sandboxed ToolRunner) ==="
echo "Profile: $PROFILE"
SHELLFISH_PROFILE="$PROFILE" .build/debug/Harness
HARNESS_EXIT=$?

# Give any in-flight sandboxed network attempts a moment to fail/log.
sleep 1

# Count requests that reached the observer, EXCLUDING the sanity check.
TOTAL_LINES=$(wc -l < "$OBSERVER_LOG" | tr -d ' ')
# grep -c always prints a number (0 if no matches); exit code 1 on zero matches
# is harmless because we don't have set -e.
EXFIL_LINES=$(grep -c "exfil" "$OBSERVER_LOG" 2>/dev/null)
EXFIL_LINES=${EXFIL_LINES:-0}

echo ""
echo "=== Observer log ==="
cat "$OBSERVER_LOG"
echo ""

echo "=== Results ==="
echo "Profile:                          $PROFILE"
echo "Harness exit code:                $HARNESS_EXIT  (1 = sandbox contained, 0 = sandbox failed)"
echo "Total observer requests:          $TOTAL_LINES"
echo "Requests matching /exfil:         $EXFIL_LINES"

if [ "$HARNESS_EXIT" = "3" ]; then
    echo ""
    echo "INCONCLUSIVE: ToolRunner did not run under the sandbox (profile load error?)."
    exit 2
elif [ "$EXFIL_LINES" = "0" ] && [ "$HARNESS_EXIT" = "1" ]; then
    echo ""
    echo "PASS: sandbox contained the exfil attempt."
    exit 0
else
    echo ""
    echo "FAIL: exfil reached observer or sandbox did not block."
    exit 1
fi
