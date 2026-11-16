# A real Supervisor on this host, set up like the run_supervisor
# job in home-assistant/supervisor .github/workflows/builder.yml.

case "$(uname -m)" in
    x86_64)  SUPERVISOR_ARCH=amd64;   SUPERVISOR_MACHINE=qemux86-64 ;;
    aarch64) SUPERVISOR_ARCH=aarch64; SUPERVISOR_MACHINE=qemuarm-64 ;;
    *)       SUPERVISOR_ARCH=; SUPERVISOR_MACHINE= ;;
esac

# Run the ha CLI. Prints the raw JSON response; fails with the CLI's message
# when the result is not ok.
ha() {
    local out
    out=$(docker exec hassio_cli ha "$@" --no-progress --raw-json 2>&1) || true
    if [ "$(jq -r '.result // empty' <<<"$out" 2>/dev/null)" != ok ]; then
        echo "[e2e] ha $*: $(jq -r '.message // empty' <<<"$out" 2>/dev/null || true)" >&2
        echo "$out" | tail -n 5 >&2
        return 1
    fi
    echo "$out"
}

# supervisor_api <METHOD> <path> [<json body>]: call the Supervisor API from the
# CLI container, which holds an API token. Same result handling as ha().
supervisor_api() {
    local out
    out=$(printf '%s' "${3:-}" | docker exec -i hassio_cli sh -c \
        'curl -sS -X "$1" -H "Authorization: Bearer $SUPERVISOR_TOKEN" -H "Content-Type: application/json" \
            ${2:+--data-binary @-} "http://supervisor$0"' "$2" "$1" "${3:+body}" 2>&1) || true
    if [ "$(jq -r '.result // empty' <<<"$out" 2>/dev/null)" != ok ]; then
        echo "[e2e] $1 $2: $(jq -r '.message // empty' <<<"$out" 2>/dev/null || echo "$out")" >&2
        return 1
    fi
    echo "$out"
}

supervisor_dump() {
    echo "[e2e] --- docker logs hassio_supervisor (last 100, no DEBUG) ---" >&2
    docker logs hassio_supervisor 2>&1 | grep -v ' DEBUG ' | tail -n 100 >&2 || true
}

# wait_for <timeout seconds> <description> <command...>
wait_for() {
    local timeout=$1 what=$2 elapsed=0
    shift 2
    until "$@" >/dev/null 2>&1; do
        [ "$elapsed" -ge "$timeout" ] && { log "timed out after ${timeout}s waiting for $what"; return 1; }
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

_supervisor_ping() {
    local ip
    ip=$(docker inspect --format '{{.NetworkSettings.Networks.hassio.IPAddress}}' hassio_supervisor 2>/dev/null)
    [ -n "$ip" ] && [ "$ip" != "<no value>" ] || return 1
    curl -fsS "http://$ip/supervisor/ping" | jq -e '.result == "ok"'
}

# Supervisor marks the system unhealthy with reason "privileged" when it runs
# inside a container host such as an OrbStack machine, and then blocks addon
# installs. That says nothing about the addon, so ignore the health condition
# for exactly that reason and fail on any other.
_supervisor_health() {
    local unhealthy
    unhealthy=$(ha resolution info | jq -c '.data.unhealthy')
    case "$unhealthy" in
        '[]') ;;
        '["privileged"]')
            log "Supervisor reports unhealthy: privileged (container host), ignoring the health condition"
            ha jobs options --ignore-conditions healthy >/dev/null ;;
        *) supervisor_dump; die "Supervisor reports unhealthy: $unhealthy" ;;
    esac
}

# On a container host (e.g. an OrbStack machine) plugin containers cannot
# lower their oom_score_adj and fail to start. Without the DNS plugin nothing
# on the hassio network resolves names, so the addon build fails. Stand in
# with a plain CoreDNS on the plugin's address.
_supervisor_dns() {
    local ip i running err
    for i in $(seq 1 30); do
        running=$(docker inspect -f '{{.State.Running}}' hassio_dns 2>/dev/null || true)
        err=$(docker inspect -f '{{.State.Error}}' hassio_dns 2>/dev/null || true)
        [ "$running" = true ] && return 0
        [ -n "$err" ] && break
        sleep 1
    done
    ip=$(ha dns info | jq -r '.data.host')
    log "DNS plugin did not start (container host?), using CoreDNS on $ip instead"
    docker rm -f hassio_dns >/dev/null 2>&1 || true
    mkdir -p "${E2E_DATA}/e2e"
    printf '. {\n    forward . /etc/resolv.conf\n    cache 30\n}\n' > "${E2E_DATA}/e2e/Corefile"
    docker run -d --quiet --name e2e-dns --network hassio --ip "$ip" \
        -v "${E2E_DATA}/e2e/Corefile:/Corefile:ro" "${COREDNS_IMAGE:-docker.io/coredns/coredns:1.15.0}" \
        -conf /Corefile >/dev/null
}

supervisor_start() {
    [ -n "$SUPERVISOR_ARCH" ] || die "unsupported architecture: $(uname -m)"
    local image
    SUPERVISOR_VERSION=$(curl -fsSL https://version.home-assistant.io/stable.json | jq -r '.supervisor')
    [ -n "$SUPERVISOR_VERSION" ] && [ "$SUPERVISOR_VERSION" != null ] || die "could not read the stable Supervisor version"
    image="ghcr.io/home-assistant/${SUPERVISOR_ARCH}-hassio-supervisor:${SUPERVISOR_VERSION}"
    log "starting Supervisor $SUPERVISOR_VERSION ($SUPERVISOR_MACHINE)"
    docker pull -q "$image" >/dev/null

    mkdir -p "$E2E_DATA"
    docker create --name hassio_supervisor \
        --privileged \
        --security-opt seccomp=unconfined \
        --security-opt apparmor=unconfined \
        -v /run/docker.sock:/run/docker.sock:rw \
        -v /run/dbus:/run/dbus:ro \
        -v /run/supervisor:/run/os:rw \
        -v "$E2E_DATA":/data:rw,slave \
        -v /etc/machine-id:/etc/machine-id:ro \
        -e SUPERVISOR_SHARE="$E2E_DATA" \
        -e SUPERVISOR_NAME=hassio_supervisor \
        -e SUPERVISOR_DEV=1 \
        -e SUPERVISOR_MACHINE="$SUPERVISOR_MACHINE" \
        "$image" >/dev/null
    docker start hassio_supervisor >/dev/null

    wait_for 300 "Supervisor API" _supervisor_ping || { supervisor_dump; die "Supervisor did not come up"; }
    wait_for 120 "ha CLI" docker exec hassio_cli ha supervisor info --no-progress --raw-json ||
        { supervisor_dump; die "ha CLI did not come up"; }
    # Health evaluations finish during setup; read them once the Supervisor
    # reports running, not at the first ping.
    wait_for 180 "Supervisor state running" sh -c \
        'docker exec hassio_cli ha info --no-progress --raw-json | jq -e ".data.state == \"running\""' ||
        { supervisor_dump; die "Supervisor did not reach state running"; }
    log "Supervisor API up"
    _supervisor_health
    _supervisor_dns
}
