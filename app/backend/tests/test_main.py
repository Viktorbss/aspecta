from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_healthz():
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readyz():
    response = client.get("/readyz")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


def test_info_reads_config_from_env(monkeypatch):
    monkeypatch.setenv("APP_MESSAGE", "Hello from test")
    monkeypatch.delenv("API_KEY", raising=False)
    body = client.get("/api/info").json()
    assert body["message"] == "Hello from test"
    assert body["secret_configured"] is False
    assert body["hostname"]


def test_info_never_returns_the_secret(monkeypatch):
    monkeypatch.setenv("API_KEY", "s3cr3t-value")
    response = client.get("/api/info")
    assert response.json()["secret_configured"] is True
    assert "s3cr3t-value" not in response.text


def test_work_burns_cpu_and_reports_pod():
    response = client.get("/api/work", params={"ms": 20})
    assert response.status_code == 200
    body = response.json()
    assert body["ms"] == 20
    assert body["hostname"]
    assert body["iterations"] > 0


def test_work_duration_is_capped():
    assert client.get("/api/work", params={"ms": 501}).status_code == 422
    assert client.get("/api/work", params={"ms": 0}).status_code == 422


def test_metrics_count_requests_by_route_template():
    client.get("/api/info")
    client.get("/healthz")
    client.get("/does-not-exist")
    text = client.get("/metrics").text
    assert 'http_requests_total{method="GET",path="/api/info",status="200"}' in text
    assert 'http_requests_total{method="GET",path="unmatched",status="404"}' in text
    assert 'path="/healthz"' not in text
    assert "/does-not-exist" not in text
