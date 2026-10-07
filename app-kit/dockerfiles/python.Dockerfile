# Python web service (FastAPI/Starlette via uvicorn workers; swap the CMD for Django/Flask).
# Copy to your repo root as "Dockerfile". Expects requirements.txt and GET /health.
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 PORT=8080
WORKDIR /app
RUN useradd --create-home --uid 10001 app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY --chown=app:app . .
USER app
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --start-period=30s --retries=3 \
  CMD python -c "import os,urllib.request; urllib.request.urlopen('http://127.0.0.1:'+os.environ.get('PORT','8080')+os.environ.get('HEALTHCHECK_PATH','/health'), timeout=2)"
# Django: gunicorn myproject.wsgi -b 0.0.0.0:$PORT
CMD ["sh", "-c", "exec gunicorn -k uvicorn.workers.UvicornWorker -b 0.0.0.0:${PORT} -w ${WEB_CONCURRENCY:-2} main:app"]
