ARG IMAGE="ghcr.io/thin-edge/tedge-container-bundle:20260629.2354"
FROM "$IMAGE"

USER root
# Note: tedge-nodered-plugin requires separate Node-RED container setup
# Disabled for now to focus on core hardware detection functionality
# RUN apk add --no-cache tedge-nodered-plugin
USER tedge

COPY tedge-configuration-plugin.toml /etc/tedge/plugins/tedge-configuration-plugin.toml
COPY tedge-nodered-plugin.toml /etc/tedge/plugins/tedge-nodered-plugin.toml
COPY --chmod=0755 startup-publish-inventory.sh /usr/local/bin/startup-publish-inventory.sh
COPY --chmod=0644 s6/inventory-publish-once/type /etc/s6-overlay/s6-rc.d/inventory-publish-once/type
COPY --chmod=0755 s6/inventory-publish-once/up /etc/s6-overlay/s6-rc.d/inventory-publish-once/up
COPY --chmod=0644 s6/user2-contents/inventory-publish-once /etc/s6-overlay/s6-rc.d/user2/contents.d/inventory-publish-once

# Fix directory permissions for s6-rc-compile to access service metadata
USER root
RUN chmod 0755 /etc/s6-overlay/s6-rc.d/inventory-publish-once && \
    chmod 0755 /etc/s6-overlay/s6-rc.d/user2/contents.d
USER tedge

ENV TEDGE_C8Y_OPERATIONS_AUTO_LOG_UPLOAD=always
