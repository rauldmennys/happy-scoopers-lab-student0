# ============================================
# Happy Scoopers DW - ciclo de vida del pipeline
# ============================================
# Si existe .venv/, los comandos de Python se toman DE AHÍ aunque no
# hayas activado el entorno. Si no existe, se usan los del PATH.
# (Así `make` funciona en cualquier terminal, activada o no.)
.PHONY: labs-pdf workspace venv up reset el-full el simulate dbt-deps dbt-build dbt-fresh \
        dbt-docs dbt-snapshot cycle cycle-full orchestrate dagster-ui \
        bi-grants web-up cloud-up cloud-urls cloud-down guide-pdf
# OJO: transform/dbt_packages NO va aquí — ese sí es un target de archivo real
# (queremos que Make lo salte si la carpeta ya existe).

VENV_BIN := $(if $(wildcard .venv/bin),$(CURDIR)/.venv/bin/,)
PY       := $(VENV_BIN)python3
DBT      := $(VENV_BIN)dbt
DAGSTER  := $(VENV_BIN)dagster


venv:          ## Crear el entorno virtual e instalar dependencias
	python3 -m venv .venv
	. .venv/bin/activate && pip install --upgrade pip \
	  && pip install -r el/requirements.txt dbt-postgres \
	  && pip install -r orchestration/requirements.txt
	@echo ""
	@echo ">>> Listo. Actívalo con:  source .venv/bin/activate"

# Fase 0: infraestructura
up:            ## Levantar oltp (:5432) y dwh (:5433)
	docker compose up -d

reset:         ## Destruir todo y reinicializar desde cero
	docker compose down -v && docker compose up -d

# Fase 1: extracción y carga (EL)
el-full:       ## Carga completa oltp -> dwh.raw (borra estado incremental)
	$(PY) el/pipeline.py --full

el:            ## Carga incremental (solo filas con modified_date nuevo)
	$(PY) el/pipeline.py

simulate:      ## Generar actividad en el OLTP para probar el incremental
	docker exec -i happy_scoopers_oltp psql -U postgres -d happy_scoopers < tools/simulate_activity.sql

# Ciclo de demostración: make up && make el-full && make simulate && make el

# Fase 2: transformación (dbt)
transform/dbt_packages:   ## (interno) instala dbt_utils la primera vez
	cd transform && DBT_PROFILES_DIR=. $(DBT) deps

dbt-deps:      ## Reinstalar los paquetes de dbt (dbt_utils)
	cd transform && DBT_PROFILES_DIR=. $(DBT) deps

dbt-build: transform/dbt_packages   ## Construir modelos + correr todos los tests
	cd transform && DBT_PROFILES_DIR=. $(DBT) build

dbt-fresh:     ## ¿Hace cuánto no corre el EL? Alerta si >24h
	cd transform && DBT_PROFILES_DIR=. $(DBT) source freshness

dbt-docs:      ## Catálogo y lineage navegables en el navegador
	cd transform && DBT_PROFILES_DIR=. $(DBT) docs generate && $(DBT) docs serve

# Ciclo completo: make el && make dbt-build

# Fase 3: la estrella
dbt-snapshot: transform/dbt_packages  ## Capturar versiones SCD2 (correr ANTES de dbt-build)
	cd transform && DBT_PROFILES_DIR=. $(DBT) snapshot

cycle: transform/dbt_packages  ## Ciclo completo del pipeline: EL -> snapshot -> build
	$(PY) el/pipeline.py
	cd transform && DBT_PROFILES_DIR=. $(DBT) snapshot && $(DBT) build

# Fase 4: carga incremental del fact
cycle-full: transform/dbt_packages  ## Reconstrucción total: EL --full + build --full-refresh
	$(PY) el/pipeline.py --full
	cd transform && DBT_PROFILES_DIR=. $(DBT) snapshot && $(DBT) build --full-refresh

# Fase 5: operación
orchestrate:   ## Ejecutar el DAG completo con Dagster (headless)
	$(DAGSTER) asset materialize -f orchestration/definitions.py --select "*"

dagster-ui:    ## UI de Dagster en localhost:3000 (lineage, runs, schedule)
	$(DAGSTER) dev -f orchestration/definitions.py

bi-grants:     ## Dar acceso de solo lectura a marts al rol de BI
	docker exec happy_scoopers_dwh psql -U dwh -d happy_scoopers_dwh -c "GRANT USAGE ON SCHEMA marts TO bi_reader; GRANT SELECT ON ALL TABLES IN SCHEMA marts TO bi_reader; ALTER DEFAULT PRIVILEGES FOR ROLE dwh IN SCHEMA marts GRANT SELECT ON TABLES TO bi_reader;"

guide-pdf:     ## Regenerar el PDF de la guía técnica (código en tema oscuro)
	$(PY) tools/md_to_pdf.py GUIA_TECNICA.md GUIA_TECNICA.pdf

labs-pdf:      ## PDF de la guía de laboratorios: versión instructor Y versión estudiante
	$(PY) tools/md_to_pdf.py GUIA_LABORATORIOS.md GUIA_LABORATORIOS.pdf
	@$(PY) -c "import re; s=open('GUIA_LABORATORIOS.md').read(); \
s=re.sub(r'> \*\*Para el instructor\.\*\*.*?(?=\n---)','',s,count=1,flags=re.S); \
s=re.sub(r'## Preparación.*?(?=\n# LAB 0)','',s,count=1,flags=re.S); \
open('/tmp/_lab_est.md','w').write(s)"
	$(PY) tools/md_to_pdf.py /tmp/_lab_est.md GUIA_LABORATORIOS_estudiante.pdf
	@echo ">>> Generados: GUIA_LABORATORIOS.pdf (instructor) y GUIA_LABORATORIOS_estudiante.pdf"

# Anexo B: portabilidad — el mismo proyecto contra DuckDB
el-duck:       ## EL completo hacia warehouse.duckdb (archivo local)
	$(PY) el/pipeline.py --full --dest duckdb

dbt-duck:      ## Construir TODA la estrella sobre DuckDB
	cd transform && DBT_PROFILES_DIR=. $(DBT) build --target duckdb

# ---- Laboratorio en la nube (Azure + Terraform) ----
cloud-up:      ## Levantar la infra del laboratorio (desde infra/)
	cd infra && terraform init && terraform apply

cloud-urls:    ## Ver las URLs de los estudiantes
	cd infra && terraform output resumen

cloud-down:    ## Destruir TODO el laboratorio (deja de facturar)
	cd infra && terraform destroy

web-up:        ## En la VM: levantar el stack con Caddy + HTTPS
	docker compose -f docker-compose.yml -f docker-compose.cloud.yml up -d

workspace:     ## Generar el workspace limpio del estudiante (../happy-scoopers-lab)
	./tools/crear_workspace_estudiante.sh
