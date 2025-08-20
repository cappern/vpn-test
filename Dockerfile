# syntax=docker/dockerfile:1.7
FROM alpine:3.22

# Metadata (optional)
LABEL org.opencontainers.image.title="vpn-probe"
LABEL org.opencontainers.image.description="Synthetic VPN login probe using openconnect + expect"
LABEL org.opencontainers.image.licenses="MIT"

# Keep the image lean: no bash/iproute2/iptables unless you truly need them.
# tini = clean PID1 to forward signals to the looped script and reap zombies.
RUN apk add --no-cache \
      openconnect \
      expect \
      ca-certificates \
      curl \
      jq \
      oath-toolkit \
      tini \
  && update-ca-certificates

# Copy the entrypoint (your probe script). Ensure POSIX /bin/sh shebang.
COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh

# Reasonable defaults (can be overridden at runtime)
ENV EXPECT_TIMEOUT=30 \
    SLEEP_INTERVAL=60 \
    FAIL_RETRY_DELAY=0 \
    LOG_PREFIX="[VPN-PROBE]" \
    MFA_MODE=password

# Use tini as init for proper signal handling.
ENTRYPOINT ["/sbin/tini","-g","--","/entrypoint.sh"]
