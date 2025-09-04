# ---- Build stage ----
FROM python:3.12-slim AS build
WORKDIR /app

# System deps to build wheels if needed
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libpq-dev gcc \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /app/requirements.txt

# hadolint ignore=DL3013
RUN pip install --upgrade pip \
 && pip install -r requirements.txt

# ---- Runtime stage ----
FROM python:3.12-slim AS runtime

# Add runtime libpq to be safe if psycopg2 is used
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 \
 && rm -rf /var/lib/apt/lists/*

# Non-root user
RUN useradd -ms /bin/bash django
WORKDIR /app

# Copy Python runtime from build stage (installed packages)
COPY --from=build /usr/local/lib/python3.12 /usr/local/lib/python3.12
COPY --from=build /usr/local/bin /usr/local/bin

# Copy app code
COPY . /app

# Prepare dirs + permissions
RUN mkdir -p /app/staticfiles /app/media \
 && chown -R django:django /app

USER django
ENV PORT=8000

# Gunicorn
CMD ["gunicorn", "bookstore.wsgi:application", "--bind", "0.0.0.0:8000"]

