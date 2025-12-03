ARG IMAGE="ghcr.io/thin-edge/tedge-container-bundle:20251202.1443"
FROM "$IMAGE"
ENV TEDGE_C8Y_OPERATIONS_AUTO_LOG_UPLOAD=always
