ARG IMAGE="ghcr.io/thin-edge/tedge-container-bundle:20260629.2354"
FROM "$IMAGE"

COPY tedge-configuration-plugin.toml /etc/tedge/plugins/tedge-configuration-plugin.toml
COPY data-hub-mapping.conf /data/tedge/data-hub-mapping.conf
COPY --chmod=0755 lib/data-hub-client.sh /usr/local/lib/data-hub-client.sh
COPY --chmod=0755 startup-publish-inventory.sh /usr/local/bin/startup-publish-inventory.sh
COPY --chmod=0755 data-hub-set-variable.sh /usr/local/bin/data-hub-set-variable.sh
COPY --chmod=0755 data-hub-list-variables.sh /usr/local/bin/data-hub-list-variables.sh
COPY --chmod=0755 s6/inventory-publish-once/type /etc/s6-overlay/s6-rc.d/inventory-publish-once/type
COPY --chmod=0755 s6/inventory-publish-once/up /etc/s6-overlay/s6-rc.d/inventory-publish-once/up
COPY --chmod=0755 s6/user2-contents/inventory-publish-once /etc/s6-overlay/s6-rc.d/user2/contents.d/inventory-publish-once
COPY --chmod=0755 s6/mapper-local/type /etc/s6-overlay/s6-rc.d/mapper-local/type
COPY --chmod=0755 s6/mapper-local/run /etc/s6-overlay/s6-rc.d/mapper-local/run
COPY --chmod=0755 s6/user2-contents/mapper-local /etc/s6-overlay/s6-rc.d/user2/contents.d/mapper-local
COPY --chmod=0755 flows/data-hub-measurements/poll.sh /etc/tedge/mappers/local/flows/data-hub-measurements/poll.sh
COPY flows/data-hub-measurements/flow.toml /etc/tedge/mappers/local/flows/data-hub-measurements/flow.toml
ENV TEDGE_C8Y_OPERATIONS_AUTO_LOG_UPLOAD=always

