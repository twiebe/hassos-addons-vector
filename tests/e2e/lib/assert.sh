# Run one test case directory. See tests/e2e/cases/*/case.json for the format:
#   backend   victorialogs | loki | none
#   options   merged over the addon defaults; "@ENDPOINT@" becomes the
#             backend's endpoint as the addon sees it
#   expect    started (bool), log_contains (substrings of the addon log),
#             record (jq expressions that must be true for every marker record)
# An optional config/ dir is copied into the addon config dir first.

_case_fail() {
    echo "[e2e] $CASE_NAME: $*" >&2
    echo "[e2e] --- addon log (last 40) ---" >&2
    addon_logs | tail -n 40 >&2
    return 1
}

case_run() {
    local dir=$1 spec backend endpoint options expect_started host_label id records expr needle
    CASE_NAME=$(basename "$dir")
    spec=$(cat "$dir/case.json")
    backend=$(jq -r '.backend' <<<"$spec")
    endpoint=$(backend_endpoint "$backend")
    expect_started=$(jq -r '.expect.started // true' <<<"$spec")
    options=$(jq -c --slurpfile d "$ADDON_DEFAULTS" --arg e "$endpoint" \
        '$d[0] * .options | walk(if type == "string" then gsub("@ENDPOINT@"; $e) else . end)' <<<"$spec")

    if [ -d "$dir/config" ]; then
        mkdir -p "$(addon_config_dir)"
        cp -R "$dir/config/." "$(addon_config_dir)/"
    fi

    log "$CASE_NAME: configuring ($backend)"
    addon_configure "$options" || _case_fail "options rejected by the Supervisor" || return 1
    addon_restart_wait "$expect_started" ||
        _case_fail "addon did not reach the expected state (started=$expect_started)" || return 1
    [ "$expect_started" = true ] && addon_check_journal_mount

    while read -r needle; do
        [ -z "$needle" ] && continue
        addon_logs | grep -qF -- "$needle" || _case_fail "addon log lacks: $needle" || return 1
    done < <(jq -r '.expect.log_contains // [] | .[]' <<<"$spec")

    [ "$backend" = none ] && return 0

    id="e2e-${CASE_NAME}-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    markers_emit "$id"
    host_label=$(jq -r 'if .transforms.rename_host_field then .transforms.host_field_name else "host" end' <<<"$options")
    records=$(backend_records "$backend" "$id" "$host_label")
    [ "$(jq 'length' <<<"$records")" -ge 2 ] ||
        _case_fail "markers $id did not arrive in $backend within 120 s (got $(jq 'length' <<<"$records"))" || return 1

    while read -r expr; do
        [ -z "$expr" ] && continue
        jq -e "all(.[]; ($expr))" <<<"$records" >/dev/null 2>&1 || {
            echo "[e2e] --- records ---" >&2
            jq -c '.[]' <<<"$records" | cut -c1-2000 >&2
            _case_fail "expectation failed: $expr" || return 1
        }
    done < <(jq -r '.expect.record // [] | .[]' <<<"$spec")
}
