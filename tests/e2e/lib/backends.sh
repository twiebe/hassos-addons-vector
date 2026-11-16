# Log backends the addon ships to. They publish their ports on the host; the
# addon reaches them through the gateway of the Supervisor's hassio network.

HASSIO_GATEWAY=172.30.32.1
VICTORIALOGS_IMAGE=${VICTORIALOGS_IMAGE:-docker.io/victoriametrics/victoria-logs:latest}
LOKI_IMAGE=${LOKI_IMAGE:-docker.io/grafana/loki:latest}

# backend_endpoint <backend>: the endpoint as the addon sees it
backend_endpoint() {
    case "$1" in
        victorialogs) echo "http://${HASSIO_GATEWAY}:9428" ;;
        loki)         echo "http://${HASSIO_GATEWAY}:3100" ;;
        none)         echo "" ;;
        *)            die "unknown backend: $1" ;;
    esac
}

backends_start() {
    log "starting VictoriaLogs and Loki"
    docker run -d --name e2e-victorialogs -p 9428:9428 "$VICTORIALOGS_IMAGE" >/dev/null
    docker run -d --name e2e-loki -p 3100:3100 "$LOKI_IMAGE" \
        -config.file=/etc/loki/local-config.yaml >/dev/null
    wait_for 120 "VictoriaLogs" curl -fsS http://127.0.0.1:9428/health || die "VictoriaLogs did not come up"
    wait_for 180 "Loki" sh -c 'curl -fsS http://127.0.0.1:3100/ready | grep -q ready' || die "Loki did not come up"
}

# Print the marker records of one backend as a JSON array of
# {"fields": {...}, "labels": {...}, "line": "..."}.
_records_victorialogs() {
    curl -fsS http://127.0.0.1:9428/select/logsql/query --data-urlencode "query=\"$1\"" |
        jq -cs 'map({fields: ., labels: {}, line: (._msg // "")})'
}

_records_loki() {
    local id=$1 host_label=$2 now
    now=$(date +%s)
    curl -fsS -G http://127.0.0.1:3100/loki/api/v1/query_range \
        --data-urlencode "query={${host_label}=~\".+\"} |= \"${id}\"" \
        --data-urlencode "start=$((now - 3600))000000000" \
        --data-urlencode "end=$((now + 60))000000000" \
        --data-urlencode "limit=100" |
        jq -c '[.data.result[] | .stream as $s | .values[] |
                {labels: $s, line: .[1], fields: (.[1] | fromjson? // {})}]'
}

# backend_records <backend> <marker id> [<loki host label>]
# Polls for up to 120 s until both markers arrived, then prints the records.
backend_records() {
    local backend=$1 id=$2 host_label=${3:-host} elapsed=0 records='[]'
    while [ "$elapsed" -lt 120 ]; do
        records=$("_records_$backend" "$id" "$host_label" 2>/dev/null || echo '[]')
        [ "$(jq 'length' <<<"$records")" -ge 2 ] && break
        sleep 3
        elapsed=$((elapsed + 3))
    done
    echo "$records"
}
