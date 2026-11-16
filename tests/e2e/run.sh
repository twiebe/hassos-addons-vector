#!/usr/bin/env bash
# End-to-end test: real Supervisor, addon built from this working tree, logs
# checked in VictoriaLogs and Loki. Needs a dedicated Linux host with systemd,
# journald, dbus and Docker, run as root. See README, "E2E tests".
#
# env: E2E_DATA (default /tmp/supervisor-e2e), KEEP=1 (no teardown),
#      HASSOS_ADDONS_DIR (local hassos-addons checkout), CASES (glob filter)
set -euo pipefail

E2E_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$E2E_DIR/../.." && pwd)
E2E_DATA=${E2E_DATA:-/tmp/supervisor-e2e}
export E2E_DIR REPO_DIR E2E_DATA

for lib in "$E2E_DIR"/lib/*.sh; do
    # shellcheck source=/dev/null
    . "$lib"
done

host_check
shopt -s nullglob
cases=("$E2E_DIR"/cases/${CASES:-*}/)
[ "${#cases[@]}" -gt 0 ] || die "no test cases match CASES='${CASES:-*}'"
teardown force
trap teardown EXIT
host_prepare
backends_launch
supervisor_start
backends_wait
addon_install

passed=0
failed=()
report=()
log "${#cases[@]} cases"
for dir in "${cases[@]}"; do
    name=$(basename "$dir")
    CASE_REASON=""
    start=$SECONDS
    if case_run "$dir"; then
        passed=$((passed + 1))
        report+=("ACK|$name|$((SECONDS - start))|")
        log "PASS $name"
    else
        failed+=("$name")
        report+=("NACK|$name|$((SECONDS - start))|${CASE_REASON:-failed}")
        log "FAIL $name"
    fi
done

# Readable protocol, also as Markdown when E2E_REPORT names a file (e.g. the
# CI job summary).
echo
echo "E2E protocol ($SUPERVISOR_MACHINE, Supervisor ${SUPERVISOR_VERSION:-?})"
for row in "${report[@]}"; do
    IFS='|' read -r status name secs reason <<<"$row"
    printf '  %-4s  %-22s %4ss  %s\n' "$status" "$name" "$secs" "$reason"
done
echo
if [ -n "${E2E_REPORT:-}" ]; then
    {
        echo "### E2E $SUPERVISOR_MACHINE: ${passed} passed, ${#failed[@]} failed"
        echo
        echo "| Result | Case | Time | Reason |"
        echo "|---|---|---|---|"
        for row in "${report[@]}"; do
            IFS='|' read -r status name secs reason <<<"$row"
            echo "| $status | \`$name\` | ${secs}s | ${reason//|/\\|} |"
        done
        echo
    } >>"$E2E_REPORT"
fi

log "${passed} passed, ${#failed[@]} failed${failed:+: ${failed[*]}}"
[ "${#failed[@]}" -eq 0 ]
