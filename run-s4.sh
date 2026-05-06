#!/bin/bash
# Shellfish PoC — S4 test runner.
# PASS = fs.read rejects the traversal arg AND the negative control reads
#        the same target after widening the workspace.
# FAIL = primary mode leaked the secret OR negative control couldn't read it.
set -u

cd "$(dirname "$0")"

echo "=== Building ==="
swift build 2>&1 | tail -10
BUILD_EXIT=${PIPESTATUS[0]}
if [ "$BUILD_EXIT" != "0" ]; then
    echo "Build failed (exit $BUILD_EXIT)"
    exit 2
fi

# --- Primary: workspace bound, traversal must be rejected ---
echo ""
echo "=== Run 1: primary (workspace = workspaces/poc) ==="
.build/debug/HarnessS4
PRIMARY_EXIT=$?

# --- Negative control: workspace widened to /tmp, same arg should now read ---
echo ""
echo "=== Run 2: negative control (workspace = /tmp) ==="
.build/debug/HarnessS4 --negative
NEGATIVE_EXIT=$?

echo ""
echo "=== Results ==="
echo "Primary HarnessS4 exit:           $PRIMARY_EXIT  (expected 1 = traversal rejected)"
echo "Negative HarnessS4 exit:          $NEGATIVE_EXIT  (expected 0 = secret leaked when workspace allows it)"

if [ "$PRIMARY_EXIT" = "1" ] && [ "$NEGATIVE_EXIT" = "0" ]; then
    echo ""
    echo "PASS: fs.read canonicalized the traversal and rejected it. Negative control proves the path-validation is what stopped the read."
    exit 0
else
    echo ""
    echo "FAIL: see exit codes above."
    exit 1
fi
