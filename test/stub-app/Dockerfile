# Local test image only. The chart default points at the real (placeholder) image.
FROM python:3.13.15-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
# Matches runAsUser in the chart.
USER 10001
EXPOSE 8080
# Single worker keeps the Prometheus counters simple for the stub.
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
