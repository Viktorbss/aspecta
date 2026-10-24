# Build stage: install runtime dependencies into a virtualenv
FROM python:3.14-slim AS build
RUN python -m venv /venv
COPY requirements.txt /tmp/requirements.txt
RUN /venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt

# Test stage: lint and unit tests; run with `docker build --target test`
FROM build AS test
COPY requirements-dev.txt /tmp/requirements-dev.txt
RUN /venv/bin/pip install --no-cache-dir -r /tmp/requirements-dev.txt
WORKDIR /srv
COPY . .
RUN /venv/bin/ruff check . && /venv/bin/ruff format --check . && /venv/bin/pytest -q

# Runtime stage (default target): only the virtualenv and the app code
FROM python:3.14-slim AS runtime
ENV PATH="/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
COPY --from=build /venv /venv
WORKDIR /srv
COPY app/ app/
# release metadata, set by the release workflow; last, so changing it does not invalidate earlier layers
ARG VERSION=dev
ARG BUILD_TIME=unknown
ENV APP_VERSION=$VERSION \
    BUILD_TIME=$BUILD_TIME
# numeric UID, so Kubernetes runAsNonRoot can verify it without /etc/passwd
USER 10001:10001
EXPOSE 8000
CMD ["python", "-m", "app.main"]
