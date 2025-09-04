
# ---- Build stage ----
FROM python:3.12-slim AS build
WORKDIR /app

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Pin APT package versions (DL3008)
ARG BUILD_ESSENTIAL_VER="*"
ARG LIBPQ_DEV_VER="*"
ARG GCC_VER="*"

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential=${BUILD_ESSENTIAL_VER} \
      libpq-dev=${LIBPQ_DEV_VER} \
      gcc=${GCC_VER} \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /app/requirements.txt

# Install Python deps without cache (DL3042)
RUN pip install --no-cache-dir -r requirements.txt

# ---- Runtime stage ----
FROM python:3.12-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Pin runtime libpq (DL3008)
ARG LIBPQ_VER="*"
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5=${LIBPQ_VER} \
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

