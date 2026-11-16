# Log backends the addon ships to. They publish their ports on the host; the
# addon reaches them through the gateway of the Supervisor's hassio network.

HASSIO_GATEWAY=172.30.32.1
VICTORIALOGS_IMAGE=${VICTORIALOGS_IMAGE:-docker.io/victoriametrics/victoria-logs:v1.54.0}
LOKI_IMAGE=${LOKI_IMAGE:-docker.io/grafana/loki:3.7.10}
# Tenant the loki-mt backend is queried as; cases send logs as this tenant.
LOKI_TENANT=e2e-tenant

# backend_endpoint <backend>: the endpoint as the addon sees it
backend_endpoint() {
    case "$1" in
        victorialogs) echo "http://${HASSIO_GATEWAY}:9428" ;;
        loki)         echo "http://${HASSIO_GATEWAY}:3100" ;;
        loki-mt)      echo "http://${HASSIO_GATEWAY}:3101" ;;
        none)         echo "" ;;
        *)            die "unknown backend: $1" ;;
    esac
}

backends_launch() {
    log "starting VictoriaLogs, Loki and multi-tenant Loki"
    docker run -d --name e2e-victorialogs -p 9428:9428 "$VICTORIALOGS_IMAGE" >/dev/null
    docker run -d --name e2e-loki -p 3100:3100 "$LOKI_IMAGE" \
        -config.file=/etc/loki/local-config.yaml -ingester.min-ready-duration=0s >/dev/null
    # A separate multi-tenant Loki: it rejects pushes without X-Scope-OrgID,
    # which would break the default Loki case.
    docker run -d --name e2e-loki-mt -p 3101:3100 "$LOKI_IMAGE" \
        -config.file=/etc/loki/local-config.yaml -auth.enabled=true -ingester.min-ready-duration=0s >/dev/null
}

backends_wait() {
    wait_for 120 "VictoriaLogs" curl -fsS http://127.0.0.1:9428/health || die "VictoriaLogs did not come up"
    wait_for 180 "Loki" sh -c 'curl -fsS http://127.0.0.1:3100/ready | grep -q ready' || die "Loki did not come up"
    wait_for 180 "multi-tenant Loki" sh -c 'curl -fsS http://127.0.0.1:3101/ready | grep -q ready' ||
        die "multi-tenant Loki did not come up"
}

# Print the marker records of one backend as a JSON array of
# {"fields": {...}, "labels": {...}, "line": "..."}. The backends' own logs
# also reach the journal and can quote the marker id (e.g. Loki logging the
# query), so keep only records whose message is exactly a marker line.
MARKER_FILTER='select((.fields.message // .line) | test("^" + $id + " (unit|container)$"))'

_records_victorialogs() {
    curl -fsS http://127.0.0.1:9428/select/logsql/query --data-urlencode "query=\"$1\"" |
        jq -cs --arg id "$1" "[.[] | {fields: ., labels: {}, line: (._msg // \"\")} | $MARKER_FILTER]"
}

# _records_loki <id> <host label> [<port> [<tenant>]]
_records_loki() {
    local id=$1 host_label=$2 port=${3:-3100} tenant=${4:-} now
    now=$(date +%s)
    curl -fsS -G "http://127.0.0.1:${port}/loki/api/v1/query_range" \
        ${tenant:+-H "X-Scope-OrgID: ${tenant}"} \
        --data-urlencode "query={${host_label}=~\".+\"} |= \"${id}\"" \
        --data-urlencode "start=$((now - 3600))000000000" \
        --data-urlencode "end=$((now + 60))000000000" \
        --data-urlencode "limit=5000" |
        jq -c --arg id "$id" "[.data.result[] | .stream as \$s | .values[] |
                {labels: \$s, line: .[1], fields: (.[1] | fromjson? // {})} | $MARKER_FILTER]"
}

# backend_records <backend> <marker id> [<loki host label>]
# Polls for up to 120 s until both markers arrived, then prints the records.
backend_records() {
    local backend=$1 id=$2 host_label=${3:-host} elapsed=0 records='[]'
    while [ "$elapsed" -lt 120 ]; do
        case "$backend" in
            victorialogs) records=$(_records_victorialogs "$id" 2>/dev/null || echo '[]') ;;
            loki)         records=$(_records_loki "$id" "$host_label" 2>/dev/null || echo '[]') ;;
            loki-mt)      records=$(_records_loki "$id" "$host_label" 3101 "$LOKI_TENANT" 2>/dev/null || echo '[]') ;;
        esac
        [ "$(jq 'length' <<<"$records")" -ge 2 ] && break
        sleep 1
        elapsed=$((elapsed + 1))
    done
    echo "$records"
}
