ARG IMAGE="ghcr.io/thin-edge/tedge-container-bundle:20260629.2354"
FROM "$IMAGE"

COPY tedge-configuration-plugin.toml /etc/tedge/plugins/tedge-configuration-plugin.toml
COPY --chmod=0644 u-os-api.sh /usr/local/lib/u-os-api.sh
COPY --chmod=0755 u-os-reboot.sh /usr/local/bin/u-os-reboot.sh
COPY --chmod=0755 log-plugins/u-os /usr/share/tedge/log-plugins/u-os
COPY --chmod=0440 sudoers-u-os-reboot /etc/sudoers.d/u-os-reboot
COPY --chmod=0755 startup-publish-inventory.sh /usr/local/bin/startup-publish-inventory.sh
COPY --chmod=0755 system-metrics.sh /usr/local/bin/system-metrics.sh
# pre-create with correct dir perms: COPY --chmod on a new file also (mis)applies to an auto-created parent dir
USER root
RUN mkdir -p /etc/s6-overlay/s6-rc.d/inventory-publish-once /etc/s6-overlay/s6-rc.d/system-metrics \
    # the container may not read the host kernel log (klogctl: Operation not
    # permitted), so don't offer the "all::dmesg" log type in Cumulocity
    && rm -f /usr/share/tedge/log-plugins/dmesg \
    # Cumulocity "Restart" reboots the whole controller via the u-OS API
    # instead of only restarting this container
    && sed -i 's#^reboot = .*#reboot = ["/usr/local/bin/u-os-reboot.sh"]#' /etc/tedge/system.toml \
    && grep -q 'u-os-reboot.sh' /etc/tedge/system.toml
USER tedge
COPY --chmod=0644 s6/inventory-publish-once/type /etc/s6-overlay/s6-rc.d/inventory-publish-once/type
COPY --chmod=0755 s6/inventory-publish-once/up /etc/s6-overlay/s6-rc.d/inventory-publish-once/up
COPY --chmod=0644 s6/user2-contents/inventory-publish-once /etc/s6-overlay/s6-rc.d/user2/contents.d/inventory-publish-once
COPY --chmod=0644 s6/system-metrics/type /etc/s6-overlay/s6-rc.d/system-metrics/type
COPY --chmod=0755 s6/system-metrics/run /etc/s6-overlay/s6-rc.d/system-metrics/run
COPY --chmod=0644 s6/user2-contents/system-metrics /etc/s6-overlay/s6-rc.d/user2/contents.d/system-metrics
ENV TEDGE_C8Y_OPERATIONS_AUTO_LOG_UPLOAD=always
