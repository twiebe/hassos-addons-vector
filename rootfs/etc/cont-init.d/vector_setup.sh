#!/usr/bin/env bashio

CONFIG_FILE="/etc/vector/vector.yaml"
TEMPLATE_FILE="/etc/vector/vector.yaml.gtpl"

print_config() {
    bashio::log.info "--- vector.yaml ---"
    while IFS= read -r line; do
        bashio::log.info "${line}"
    done < <(sed 's/\(password:\s*\)"[^"]*"/\1"***"/' "${CONFIG_FILE}")
    bashio::log.info "---"
}

bashio::log.info "Configuring Vector..."

# ---------------------------------------------------------------------------
# Override config — skip generation entirely if enabled
# ---------------------------------------------------------------------------

if bashio::config.true 'override_config'; then
    OVERRIDE_PATH=$(bashio::config 'override_config_path')

    # Resolve the override path. A relative path is looked up inside the addon
    # config dir (mounted at /config); an absolute path is used as-is, which
    # keeps older configs that set e.g. /config/vector.yaml working.
    case "${OVERRIDE_PATH}" in
        /*) RESOLVED_OVERRIDE_PATH="${OVERRIDE_PATH}" ;;
        *)  RESOLVED_OVERRIDE_PATH="/config/${OVERRIDE_PATH}" ;;
    esac

    bashio::log.info "Override config enabled, using: ${RESOLVED_OVERRIDE_PATH}"
    if [ ! -f "${RESOLVED_OVERRIDE_PATH}" ]; then
        bashio::log.fatal "Override config file not found: ${RESOLVED_OVERRIDE_PATH} (from override_config_path='${OVERRIDE_PATH}')"
        exit 1
    fi
    cp "${RESOLVED_OVERRIDE_PATH}" "${CONFIG_FILE}"
    print_config
    exit 0
fi

# ---------------------------------------------------------------------------
# Generate config via tempio
# ---------------------------------------------------------------------------

jq -n \
    --argjson lowercase_fields   "$(bashio::config 'transforms.lowercase_fields')" \
    --argjson rename_host_field  "$(bashio::config 'transforms.rename_host_field')" \
    --arg     host_field_name    "$(bashio::config 'transforms.host_field_name')" \
    --arg     sink_type          "$(bashio::config 'sink_type')" \
    --arg     vl_endpoint        "$(bashio::config 'sink_victorialogs.endpoint')" \
    --arg     vl_auth_user       "$(bashio::config 'sink_victorialogs.auth_user'     2>/dev/null || echo '')" \
    --arg     vl_auth_password   "$(bashio::config 'sink_victorialogs.auth_password' 2>/dev/null || echo '')" \
    --arg     vl_stream_fields   "$(bashio::config 'sink_victorialogs.stream_fields' 2>/dev/null || echo '')" \
    --arg     vl_ignore_fields   "$(bashio::config 'sink_victorialogs.ignore_fields' 2>/dev/null || echo '')" \
    --arg     loki_endpoint      "$(bashio::config 'sink_loki.endpoint'              2>/dev/null || echo '')" \
    --arg     loki_auth_user     "$(bashio::config 'sink_loki.auth_user'             2>/dev/null || echo '')" \
    --arg     loki_auth_password "$(bashio::config 'sink_loki.auth_password'         2>/dev/null || echo '')" \
    --arg     loki_tenant_id     "$(bashio::config 'sink_loki.tenant_id'             2>/dev/null || echo '')" \
    --arg     loki_encoding      "$(bashio::config 'sink_loki.encoding'              2>/dev/null || echo 'text')" \
    '{
        lowercase_fields:   $lowercase_fields,
        rename_host_field:  $rename_host_field,
        host_field_name:    $host_field_name,
        sink_type:          $sink_type,
        vl_endpoint:        $vl_endpoint,
        vl_auth_user:       $vl_auth_user,
        vl_auth_password:   $vl_auth_password,
        vl_stream_fields:   $vl_stream_fields,
        vl_ignore_fields:   $vl_ignore_fields,
        loki_endpoint:      $loki_endpoint,
        loki_auth_user:     $loki_auth_user,
        loki_auth_password: $loki_auth_password,
        loki_tenant_id:     $loki_tenant_id,
        loki_encoding:      $loki_encoding
    }' \
| tempio \
    -template "${TEMPLATE_FILE}" \
    -out "${CONFIG_FILE}"

print_config
