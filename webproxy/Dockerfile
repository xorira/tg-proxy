FROM alpine:3.19
RUN apk add --no-cache ca-certificates tzdata socat \
 && adduser -D -u 1001 -h /app tproxy
WORKDIR /app
COPY repo/tproxy-server ./tproxy-server
COPY mtg-obf2 ./mtg-obf2
COPY relay/entrypoint.sh ./entrypoint.sh
COPY relay/mtg.toml /etc/mtg/config.toml
RUN chmod 0755 ./tproxy-server ./entrypoint.sh ./mtg-obf2 \
 && chmod 0644 /etc/mtg/config.toml
USER tproxy
EXPOSE 8082
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8081/readyz >/dev/null 2>&1 || exit 1
ENTRYPOINT ["./entrypoint.sh"]
