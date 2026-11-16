# The addon under test, built by the Supervisor from this working tree.

ADDON_SLUG=local_vector_dev
# The container is app_<slug> on Supervisor 2026.x and addon_<slug> before.
addon_container() {
    docker ps -a --format '{{.Names}}' | grep -xE "(app|addon)_${ADDON_SLUG}" | head -n 1
}
ADDON_DEFAULTS="${E2E_DATA}/e2e/defaults.json"

# Supervisor 2026.x renamed addons/ to apps/ and addon_configs/ to app_configs/
# in its data dir. Pick whichever this Supervisor created.
_data_dir() {
    if [ -d "${E2E_DATA}/$1" ]; then echo "${E2E_DATA}/$1"; else echo "${E2E_DATA}/$2"; fi
}
addon_local_dir()  { _data_dir apps/local addons/local; }
addon_config_dir() { echo "$(_data_dir app_configs addon_configs)/${ADDON_SLUG}"; }

# config.yaml and translations/ live in twiebe/hassos-addons (vector-dev/).
_addon_metadata() {
    local dst=$1 tmp
    if [ -n "${HASSOS_ADDONS_DIR:-}" ]; then
        log "addon metadata from $HASSOS_ADDONS_DIR/vector-dev"
        cp -R "$HASSOS_ADDONS_DIR/vector-dev/config.yaml" "$HASSOS_ADDONS_DIR/vector-dev/translations" "$dst/"
    else
        log "addon metadata from twiebe/hassos-addons main"
        tmp=$(mktemp -d)
        curl -fsSL https://codeload.github.com/twiebe/hassos-addons/tar.gz/refs/heads/main |
            tar -xz -C "$tmp" --strip-components=1 hassos-addons-main/vector-dev
        cp -R "$tmp/vector-dev/config.yaml" "$tmp/vector-dev/translations" "$dst/"
        rm -rf "$tmp"
    fi
    # Without an image, the Supervisor builds the addon from the Dockerfile.
    sed -i '/^image:/d' "$dst/config.yaml"
}

addon_install() {
    local dst
    dst="$(addon_local_dir)/vector"
    mkdir -p "$dst" "${E2E_DATA}/e2e"
    cp -R "$REPO_DIR/Dockerfile" "$REPO_DIR/build.yaml" "$REPO_DIR/rootfs" "$dst/"
    _addon_metadata "$dst"

    ha store reload >/dev/null || die "store reload failed"
    log "installing $ADDON_SLUG (local build)"
    ha apps install "$ADDON_SLUG" >/dev/null || { supervisor_dump; die "addon install failed"; }
    ha apps info "$ADDON_SLUG" | jq '.data.options' > "$ADDON_DEFAULTS"
}

addon_logs() {
    local c
    c=$(addon_container)
    [ -n "$c" ] && docker logs "$c" 2>&1 || true
}

addon_configure() {
    supervisor_api POST "/addons/${ADDON_SLUG}/options" "$(jq -c '{options: .}' <<<"$1")" >/dev/null
}

_addon_state() {
    ha apps info "$ADDON_SLUG" | jq -r '.data.state'
}

_addon_started() {
    [ "$(_addon_state)" = started ] && addon_logs | grep -q 'Vector has started'
}

_addon_not_started() {
    [ "$(_addon_state)" != started ]
}

# addon_restart_wait <true|false>: restart and wait until Vector runs, or,
# with false, until the addon has stopped again.
addon_restart_wait() {
    ha apps stop "$ADDON_SLUG" >/dev/null 2>&1 || true
    if [ "$1" = true ]; then
        ha apps start "$ADDON_SLUG" >/dev/null || return 1
        addon_check_journal_mount
        wait_for 60 "addon start" _addon_started
    else
        ha apps start "$ADDON_SLUG" >/dev/null 2>&1 || true
        sleep 5
        wait_for 60 "addon stop" _addon_not_started
    fi
}

# On a plain Linux host, journald: true might mount nothing, which would make
# every case time out for a reason that has nothing to do with the addon.
addon_check_journal_mount() {
    local c
    c=$(addon_container)
    [ -n "$c" ] || die "addon container not found after start"
    docker inspect -f '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' "$c" |
        grep -qx /var/log/journal || die "addon has no /var/log/journal mount"
}
