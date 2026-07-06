ARG IMAGE="ghcr.io/thin-edge/tedge-container-bundle:20260629.2354"
FROM "$IMAGE"
ENV TEDGE_C8Y_OPERATIONS_AUTO_LOG_UPLOAD=always
