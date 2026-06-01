FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    tar \
    gzip \
    rclone \
    tzdata \
    curl \
    jq

COPY backup.sh          /usr/local/bin/backup.sh
COPY entrypoint.sh      /usr/local/bin/entrypoint.sh
COPY splunk-alert.sh    /usr/local/bin/splunk-alert.sh
COPY splunk-entrypoint.sh /usr/local/bin/splunk-entrypoint.sh

RUN chmod +x \
    /usr/local/bin/backup.sh \
    /usr/local/bin/entrypoint.sh \
    /usr/local/bin/splunk-alert.sh \
    /usr/local/bin/splunk-entrypoint.sh

WORKDIR /volumes

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
