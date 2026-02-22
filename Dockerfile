ARG BUILD_FROM
FROM $BUILD_FROM

ARG \
  BUILD_ARCH \
  BUILD_VERSION \
  VECTOR_VERSION="0.53.0"

LABEL \
  io.hass.version=${BUILD_VERSION} \
  io.hass.type="addon" \
  io.hass.arch="${BUILD_ARCH}"

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        systemd && \
    rm -rf /var/lib/apt/lists/* && \
    apt clean && \
    ARCH="${BUILD_ARCH}" && \
    if [ "${BUILD_ARCH}" = "aarch64" ]; then ARCH="arm64"; else ARCH="amd64"; fi && \
    curl -fsSL -o /tmp/vector.deb \
        "https://github.com/vectordotdev/vector/releases/download/v${VECTOR_VERSION}/vector_${VECTOR_VERSION}-1_${ARCH}.deb" && \
    dpkg -i /tmp/vector.deb && \
    rm /tmp/vector.deb

COPY rootfs /
RUN chmod +x /etc/cont-init.d/vector_setup.sh /etc/services.d/vector/run
