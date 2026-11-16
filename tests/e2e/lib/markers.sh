# Marker log lines with the journald fields the addon's transforms and labels
# use: one from a container (CONTAINER_NAME, via the journald log driver) and
# one from a transient systemd unit (_SYSTEMD_UNIT, PRIORITY 4).

MARKER_IMAGE=${MARKER_IMAGE:-docker.io/library/busybox:latest}

markers_emit() {
    local id=$1
    docker run --rm --log-driver journald --name "e2e-c-$id" "$MARKER_IMAGE" echo "$id container" >/dev/null
    systemd-run --quiet --wait --unit "e2e-u-$id" systemd-cat -p warning echo "$id unit"
}
