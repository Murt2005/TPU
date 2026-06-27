#!/usr/bin/env bash
# ==============================================================================
# run_tests.sh — build + run every RTL testbench, print a pass/fail summary.
#
# Usage:
#   ./run_tests.sh                # run every registered test
#   ./run_tests.sh fifo pe mmu    # run only the named test(s)
#
# Exit code is 0 only if every test compiled and passed (safe to use in CI).
# Per-test build/run logs are written to sim/logs/<name>.log
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SIM_DIR="sim"
LOG_DIR="$SIM_DIR/logs"
mkdir -p "$LOG_DIR"

# Must match the TESTS list in the Makefile
ALL_TESTS=(fifo pe mmu accumulator systolic_data_setup weight_fifo bias activation \
           unified_buffer weight_loader \
           mmu_accum accum_bias bias_activation weight_fifo_mmu \
           weight_loader_fifo tpu_core)
TESTS=("${@:-${ALL_TESTS[@]}}")

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

declare -a RESULTS=()
EXIT_CODE=0

for t in "${TESTS[@]}"; do
    echo -e "${YELLOW}${BOLD}── ${t} ──${NC}"

    # 1) Build (uses the Makefile so the dependency list stays single-sourced)
    BUILD_LOG="$LOG_DIR/${t}.build.log"
    if ! make -s "build-${t}" >"$BUILD_LOG" 2>&1; then
        echo -e "  ${RED}COMPILE ERROR${NC} — see $BUILD_LOG"
        tail -n 10 "$BUILD_LOG" | sed 's/^/    /'
        RESULTS+=("${t}|COMPILE_ERROR")
        EXIT_CODE=1
        echo
        continue
    fi

    # 2) Run
    RUN_LOG="$LOG_DIR/${t}.log"
    (cd "$SIM_DIR" && vvp "${t}.vvp") | tee "$RUN_LOG"

    # 3) Classify pass/fail from console output.
    #    Convention used across all testbenches: $error(...) on any mismatch,
    #    and a final ">>> ... PASSED <<<" line when errors == 0.
    if grep -qE '\$error|\[FAIL\]' "$RUN_LOG"; then
        RESULTS+=("${t}|FAIL")
        EXIT_CODE=1
    elif grep -qiE 'PASSED' "$RUN_LOG"; then
        RESULTS+=("${t}|PASS")
    else
        # No explicit pass/fail banner found — flag for manual review rather
        # than silently calling it a pass.
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
