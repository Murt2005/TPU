#!/usr/bin/env bash
# builds and runs every testbench (or the named ones), prints a pass/fail summary
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SIM_DIR="sim"
LOG_DIR="$SIM_DIR/logs"
mkdir -p "$LOG_DIR"

read -r -a ALL_TESTS <<< "$(make -s print-tests)"
if [ ${#ALL_TESTS[@]} -eq 0 ]; then
    echo "run_tests.sh: 'make print-tests' returned no tests -- check TB_DIR in the Makefile" >&2
    exit 1
fi
TESTS=("${@:-${ALL_TESTS[@]}}")

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

declare -a RESULTS=()
EXIT_CODE=0

for t in "${TESTS[@]}"; do
    echo -e "${YELLOW}${BOLD}── ${t} ──${NC}"

    BUILD_LOG="$LOG_DIR/${t}.build.log"
    if ! make -s "build-${t}" >"$BUILD_LOG" 2>&1; then
        echo -e "  ${RED}COMPILE ERROR${NC} — see $BUILD_LOG"
        tail -n 10 "$BUILD_LOG" | sed 's/^/    /'
        RESULTS+=("${t}|COMPILE_ERROR")
        EXIT_CODE=1
        echo
        continue
    fi

    RUN_LOG="$LOG_DIR/${t}.log"
    (cd "$SIM_DIR" && vvp "${t}.vvp") | tee "$RUN_LOG"

    # pass needs the >>> ... PASSED <<< banner; $error or [FAIL] means failure
    if grep -qE '\$error|\[FAIL\]' "$RUN_LOG"; then
        RESULTS+=("${t}|FAIL")
        EXIT_CODE=1
    elif grep -qiE 'PASSED' "$RUN_LOG"; then
        RESULTS+=("${t}|PASS")
    else
        # no banner: flag it rather than call it a pass
        RESULTS+=("${t}|UNKNOWN")
        EXIT_CODE=1
    fi
    echo
done

echo "=========================== TEST SUMMARY ==========================="
printf "%-28s %s\n" "TESTBENCH" "RESULT"
printf "%-28s %s\n" "---------" "------"
for r in "${RESULTS[@]}"; do
    name="${r%%|*}"
    status="${r##*|}"
    case "$status" in
        PASS) color=$GREEN ;;
        *)    color=$RED ;;
    esac
    printf "%-28s ${color}%s${NC}\n" "$name" "$status"
done
echo "======================================================================"

if [ "$EXIT_CODE" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"
else
    echo -e "${RED}${BOLD}SOME TESTS FAILED — see logs in ${LOG_DIR}/${NC}"
fi

exit "$EXIT_CODE"
