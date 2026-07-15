FROM postgres:16-alpine

RUN apk add --no-cache restic=0.18.1-r7

COPY scripts/backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

ENTRYPOINT ["/usr/local/bin/backup.sh"]
