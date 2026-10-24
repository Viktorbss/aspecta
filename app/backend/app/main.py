"""aspecta backend: small JSON API with health probes and Prometheus metrics."""

import os
import socket
import time
from datetime import UTC, datetime

import uvicorn
from fastapi import FastAPI, Query, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

APP_VERSION = os.getenv("APP_VERSION", "dev")
# baked into the image by the release workflow; proves which build is running
BUILD_TIME = os.getenv("BUILD_TIME", "unknown")
# changes with every new pod; proves a rollout happened
STARTED_AT = datetime.now(UTC).isoformat(timespec="seconds")

REQUESTS = Counter("http_requests_total", "HTTP requests handled", ["method", "path", "status"])
LATENCY = Histogram("http_request_duration_seconds", "HTTP request latency", ["method", "path"])

# probes and scrapes would drown real traffic in the request metrics
UNTRACKED_PATHS = {"/healthz", "/readyz", "/metrics"}

# upper bound for /api/work, so a single request cannot pin a CPU for long
MAX_WORK_MS = 500

app = FastAPI(title="aspecta-backend", version=APP_VERSION)


@app.middleware("http")
async def record_metrics(request: Request, call_next):
    start = time.perf_counter()
    status = 500  # stays 500 when the handler raises
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    finally:
        route = request.scope.get("route")
        # label by route template, not raw URL, so label cardinality stays bounded
        path = route.path if route else "unmatched"
        if path not in UNTRACKED_PATHS:
            REQUESTS.labels(request.method, path, str(status)).inc()
            LATENCY.labels(request.method, path).observe(time.perf_counter() - start)


@app.get("/api/info")
def info() -> dict:
    return {
        "message": os.getenv("APP_MESSAGE", "Hello from aspecta"),
        "version": APP_VERSION,
        "built_at": BUILD_TIME,
        "started_at": STARTED_AT,
        "hostname": socket.gethostname(),
        # never return the secret itself, only whether it was provided
        "secret_configured": bool(os.getenv("API_KEY")),
    }


@app.get("/api/work")
def work(ms: int = Query(100, ge=1, le=MAX_WORK_MS)) -> dict:
    """Burn CPU for `ms` milliseconds. Demo load for the HorizontalPodAutoscaler."""
    deadline = time.perf_counter() + ms / 1000
    iterations = 0
    while time.perf_counter() < deadline:
        iterations += 1
    return {"hostname": socket.gethostname(), "ms": ms, "iterations": iterations}


@app.get("/healthz")
def healthz() -> dict:
    """Liveness: the process is up and serving requests."""
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict:
    """Readiness: the app can take traffic (no external dependencies to check yet)."""
    return {"status": "ready"}


@app.get("/metrics")
def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8000")),
        log_level=os.getenv("LOG_LEVEL", "info").lower(),
    )
