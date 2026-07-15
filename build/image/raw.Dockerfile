ARG IMAGE="ghcr.io/thin-edge/tedge-container-bundle:20260629.2354"
FROM "$IMAGE"

COPY tedge-configuration-plugin.toml /etc/tedge/plugins/tedge-configuration-plugin.toml
COPY --chmod=0755 startup-publish-inventory.sh /usr/local/bin/startup-publish-inventory.sh

ENTRYPOINT ["/usr/local/bin/startup-publish-inventory.sh"]
ENV TEDGE_C8Y_OPERATIONS_AUTO_LOG_UPLOAD=always
