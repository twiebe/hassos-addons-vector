# Host checks, host preparation and teardown.
# The host must be dedicated to the test: host_prepare changes the Docker log
# driver and the journal storage and does not restore them.

log() { echo "[e2e] $(printf "%4ds" "$SECONDS") $*"; }
die() { echo "[e2e] ERROR: $*" >&2; exit 1; }

host_check() {
    [ "$(id -u)" = 0 ] || die "run as root"
    local cmd
    for cmd in systemctl systemd-run journalctl docker jq curl; do
        command -v "$cmd" >/dev/null || die "missing command: $cmd"
    done
    [ -s /etc/machine-id ] || die "missing /etc/machine-id"
    [ -d /run/dbus ] || die "missing /run/dbus (dbus not running?)"
    systemctl is-active --quiet systemd-journald || die "systemd-journald is not running"
    docker info >/dev/null 2>&1 || die "docker is not running"
}

# Make container logs land in journald with CONTAINER_NAME, as on HAOS, and
# keep the journal in /var/log/journal, where the addon's config reads it.
host_prepare() {
    local cfg=/etc/docker/daemon.json current
    current=$(jq -r '."log-driver" // empty' "$cfg" 2>/dev/null || true)
    if [ "$current" != journald ]; then
        log "setting docker log-driver to journald"
        mkdir -p /etc/docker
        if [ -s "$cfg" ]; then
            jq '. + {"log-driver": "journald"}' "$cfg" > "$cfg.new"
        else
            echo '{"log-driver": "journald"}' > "$cfg.new"
        fi
        mv "$cfg.new" "$cfg"
        systemctl restart docker
    fi
    if [ ! -d /var/log/journal ]; then
        log "enabling persistent journal in /var/log/journal"
        mkdir -p /var/log/journal
        systemd-tmpfiles --create --prefix /var/log/journal
        systemctl restart systemd-journald
        journalctl --flush
    fi
    # Storage=volatile or a broken journald would leave the addon nothing to
    # read; every case would then wait out its marker timeout.
    local probe="e2e-probe-$$-$RANDOM" i
    echo "$probe" | systemd-cat -t e2e-probe
    for i in 1 2 3 4 5 6 7 8 9 10; do
        journalctl --flush 2>/dev/null || true
        journalctl -q -D /var/log/journal -t e2e-probe 2>/dev/null | grep -q "$probe" && return 0
        sleep 1
    done
    die "journal entries do not reach /var/log/journal (Storage=volatile?)"
}

# teardown [force]: KEEP=1 only skips the teardown at exit, not the one
# before setup.
teardown() {
    if [ "${KEEP:-}" = 1 ] && [ "${1:-}" != force ]; then
        log "KEEP=1, leaving containers and ${E2E_DATA} in place"
        return 0
    fi
    local ids
    ids=$(docker ps -aq --filter 'name=^(hassio_|addon_|app_|homeassistant$|e2e-)' 2>/dev/null || true)
    # docker's name filter is a substring regex on some versions, so check again.
    ids=$(for id in $ids; do
        n=$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')
        echo "$n" | grep -qE '^(hassio_|addon_|app_|homeassistant$|e2e-)' && echo "$id"
    done)
    # Stop the Supervisor first, or it recreates plugin containers meanwhile.
    docker rm -f hassio_supervisor >/dev/null 2>&1 || true
    [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1 || true
    docker network rm hassio >/dev/null 2>&1 || true
    rm -rf "${E2E_DATA:?}"
}
