ARG IMAGE="ghcr.io/thin-edge/tedge-container-bundle:20260629.2354"
FROM "$IMAGE"

USER root
# Adds the nodered-project/nodered-flows software management plugins so that
# node-red flows/projects can be deployed via Cumulocity software management.
# Node-RED itself runs in a separate container (see the "nodered" service in
# the u-OS app manifest) and is reached over the "tedge" docker network.
RUN apk add --no-cache tedge-nodered-plugin
USER tedge

COPY tedge-configuration-plugin.toml /etc/tedge/plugins/tedge-configuration-plugin.toml
COPY tedge-nodered-plugin.toml /etc/tedge/plugins/tedge-nodered-plugin.toml
COPY --chmod=0755 startup-publish-inventory.sh /usr/local/bin/startup-publish-inventory.sh
COPY --chmod=0644 s6/inventory-publish-once/type /etc/s6-overlay/s6-rc.d/inventory-publish-once/type
COPY --chmod=0755 s6/inventory-publish-once/up /etc/s6-overlay/s6-rc.d/inventory-publish-once/up
COPY --chmod=0644 s6/user2-contents/inventory-publish-once /etc/s6-overlay/s6-rc.d/user2/contents.d/inventory-publish-once
ENV TEDGE_C8Y_OPERATIONS_AUTO_LOG_UPLOAD=always
