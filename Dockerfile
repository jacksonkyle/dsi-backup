FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    tar \
    gzip \
    rclone \
    tzdata \
    curl

COPY backup.sh /usr/local/bin/backup.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/entrypoint.sh

WORKDIR /volumes

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
