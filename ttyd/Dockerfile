FROM tsl0922/ttyd:latest

# Herramientas del curso: Python, git, cliente Postgres, curl
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-venv \
      git \
      postgresql-client \
      curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# dbt en las versiones EXACTAS del proyecto (autocontenido en la imagen)
RUN pip3 install --no-cache-dir --break-system-packages \
      dbt-core==1.12.2 dbt-postgres==1.11.0

WORKDIR /opt/happy-scoopers
