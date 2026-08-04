# Laboratorio — Data Warehouse Happy Scoopers

Vas a construir un data warehouse dimensional, **una dimensión a la vez**.
Sigue `GUIA_LABORATORIOS.md`.

## Arranque (una sola vez)

```bash
docker compose up -d              # levanta la base fuente y el warehouse
make venv                         # crea el entorno de Python
source .venv/bin/activate         # actívalo (en CADA terminal nueva)
cd transform && dbt deps && cd .. # instala los paquetes de dbt
```

Comprobar que la fuente está viva:

```bash
docker exec -it happy_scoopers_oltp psql -U postgres -d happy_scoopers \
  -c "SELECT count(*) FROM oltp.customers;"       # debe decir 103058
```

## Qué hay en cada carpeta

| Carpeta | Qué es | ¿La tocas? |
|---|---|---|
| `transform/models/` | Tus modelos dbt | **Sí, todo el curso** |
| `transform/snapshots/` | Historia SCD2 | **Sí, desde el Lab 4** |
| `el/pipeline.py` | Qué tablas se extraen | **Sí, la lista `TABLES`** |
| `tools/` | Simulador de actividad | Solo lo ejecutas |
| `Makefile` | Atajos de comandos | Lo lees, no lo editas |

## Comandos que vas a usar

```bash
make el-full     # carga completa oltp -> raw
make el          # carga incremental (solo lo nuevo)
make simulate    # genera actividad en la fuente
make dbt-build   # construye modelos + corre tests
make cycle       # el ciclo completo: EL -> snapshot -> build
```

## Herramientas web

- **pgAdmin** — http://localhost:5050 (`admin@happyscoopers.com` / `admin`)
- **Metabase** — http://localhost:3000
