"""Stand-in for data-sync, used only for local Minikube tests."""
import os

from fastapi import FastAPI, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, generate_latest

app = FastAPI()
REQUESTS = Counter("data_sync_requests_total", "Requests served", ["path"])


@app.get("/health")
def health():
    REQUESTS.labels(path="/health").inc()
    return {"status": "ok"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/")
def root():
    REQUESTS.labels(path="/").inc()
    return {"service": "data-sync", "env": os.getenv("APP_ENV", "unknown")}
