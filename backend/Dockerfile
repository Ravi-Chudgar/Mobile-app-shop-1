FROM python:3.12-slim

WORKDIR /srv/backend

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt gunicorn==23.0.0

COPY . .
RUN chmod +x scripts/docker-entrypoint.sh

EXPOSE 9999

# Entrypoint waits for DynamoDB/S3 and seeds sample data on first boot.
# Gunicorn instead of `python run.py` so the Werkzeug debug debugger is never
# exposed through the public tunnel; access logs on so `compose logs` shows
# every request.
ENTRYPOINT ["/srv/backend/scripts/docker-entrypoint.sh"]
CMD ["gunicorn", "--bind", "0.0.0.0:9999", "--workers", "2", "--threads", "4", \
     "--timeout", "60", "--access-logfile", "-", "run:app"]
