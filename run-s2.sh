#!/bin/bash
# Shellfish PoC — S2 test runner.
# PASS = broker denied shell.exec from the injected MCP response.
# FAIL = shell ran AND/OR exfil reached observer.
set -u

cd "$(dirname "$0")"

OBSERVER_LOG=/tmp/shellfish-poc-observer.log

echo "=== Building ==="
swift build 2>&1 | tail -10
BUILD_EXIT=${PIPESTATUS[0]}
if [ "$BUILD_EXIT" != "0" ]; then
    echo "Build failed (exit $BUILD_EXIT)"
    exit 2
fi

echo ""
echo "=== Starting AttackerObserver on 127.0.0.1:9999 ==="
: > "$OBSERVER_LOG"
.build/debug/AttackerObserver &
OBSERVER_PID=$!
sleep 1
trap "kill $OBSERVER_PID 2>/dev/null; wait $OBSERVER_PID 2>/dev/null" EXIT

# Sanity check the observer.
echo ""
echo "=== Sanity check: observer reachable ==="
SANITY=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:9999/sanity?check=1" || echo "FAIL")
echo "Direct curl HTTP code: $SANITY (expected 200)"

# --- Primary run: broker should deny shell.exec ---
echo ""
echo "=== Run 1: primary (no shell capability — broker should deny) ==="
.build/debug/HarnessS2
PRIMARY_EXIT=$?

# --- Negative control: broker has shell capability and approves ---
echo ""
echo "=== Run 2: negative control (shell granted — broker should approve, exfil should hit observer) ==="
.build/debug/HarnessS2 --negative
NEGATIVE_EXIT=$?

# Settle.
sleep 1

echo ""
echo "=== Observer log ==="
cat "$OBSERVER_LOG"
echo ""

EXFIL_HITS=$(grep -c "exfil" "$OBSERVER_LOG" 2>/dev/null)
EXFIL_HITS=${EXFIL_HITS:-0}

echo "=== Results ==="
echo "Primary HarnessS2 exit:           $PRIMARY_EXIT  (expected 1 = denied)"
echo "Negative HarnessS2 exit:          $NEGATIVE_EXIT  (expected 0 = approved+ran)"
echo "Total observer /exfil hits:       $EXFIL_HITS  (expected 1 — only from negative control)"

if [ "$PRIMARY_EXIT" = "1" ] && [ "$NEGATIVE_EXIT" = "0" ] && [ "$EXFIL_HITS" = "1" ]; then
    echo ""
    echo "PASS: broker denied the injected shell call. Negative control proves the shell would have run otherwise."
    exit 0
else
    echo ""
    echo "FAIL: see exit codes above."
    exit 1
fi
