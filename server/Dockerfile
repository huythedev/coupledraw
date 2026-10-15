# syntax=docker/dockerfile:1
FROM python:3.12-slim-bookworm

LABEL org.opencontainers.image.title="CoupleDraw backend" \
      org.opencontainers.image.source="https://github.com/huythedev/coupledraw" \
      org.opencontainers.image.licenses="MIT"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Include the optional APNs client so the same image supports every alert mode.
COPY requirements-push.txt ./
RUN python -m pip install --no-cache-dir --only-binary=:all: -r requirements-push.txt \
    && groupadd --gid 10001 coupledraw \
    && useradd --uid 10001 --gid coupledraw --no-create-home --shell /usr/sbin/nologin coupledraw \
    && mkdir /data \
    && chown coupledraw:coupledraw /data \
    && chmod 700 /data

COPY coupledraw_server.py ./

USER 10001:10001
VOLUME ["/data"]
EXPOSE 8787
# The server handles KeyboardInterrupt and closes its listener on SIGINT.
STOPSIGNAL SIGINT
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD ["python", "-c", "from urllib.request import urlopen; urlopen('http://127.0.0.1:8787/v1/capabilities', timeout=3).close()"]

ENTRYPOINT ["python", "/app/coupledraw_server.py"]
CMD ["serve", "--db", "/data/coupledraw.sqlite3", "--host", "0.0.0.0", "--port", "8787"]
