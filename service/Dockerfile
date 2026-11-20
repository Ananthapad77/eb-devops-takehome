# ---- build stage: byte-compile the app ----
FROM python:3.12.8-slim-bookworm AS builder
WORKDIR /build
COPY app.py .
RUN python -m compileall -q app.py

# ---- runtime stage ----
FROM python:3.12.8-slim-bookworm
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PORT=8080
RUN groupadd --gid 10001 app && \
    useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY --from=builder --chown=10001:10001 /build/app.py .
USER 10001:10001
EXPOSE 8080
CMD ["python", "app.py"]
