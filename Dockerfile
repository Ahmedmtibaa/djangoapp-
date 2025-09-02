FROM python:3.12-slim AS build
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential curl libpq-dev && \
    rm -rf /var/lib/apt/lists/*
COPY requirements.txt /app/requirements.txt
RUN pip install --upgrade pip && pip install -r requirements.txt

FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 DJANGO_SETTINGS_MODULE=bookstore.settings PORT=8000
RUN addgroup --system django && adduser --system --ingroup django django
WORKDIR /app
COPY --from=build /usr/local/lib/python3.12 /usr/local/lib/python3.12
COPY --from=build /usr/local/bin /usr/local/bin
COPY . /app
RUN mkdir -p /app/staticfiles /app/media && chown -R django:django /app
USER django
EXPOSE 8000
ENTRYPOINT ["bash","-lc","python manage.py migrate && python manage.py collectstatic --noinput || true && gunicorn bookstore.wsgi:application --bind 0.0.0.0:${PORT} --workers 3 --timeout 90"]
