#!/usr/bin/env python3
"""
Fase 1 - Extracción y Carga (EL) con dlt
========================================
Copia las tablas del OLTP (localhost:5432, schema oltp) al warehouse
(localhost:5433, schema raw) SIN transformar nada. La transformación
es trabajo de dbt, dentro del warehouse (patrón ELT).

Equivalencias con el mundo SSIS del curso original:
  * Data Flow (OLE DB source -> destination)  -> este script
  * Tabla IncrementalLoads + Get_LastLoadedDate -> estado de dlt
    (se guarda solo, en la tabla raw._dlt_pipeline_state del destino)
  * Tabla Lineage                             -> raw._dlt_loads
    (un registro por carga, con timestamp y estado)

Uso:
  python pipeline.py           # incremental (la 1a vez equivale a full)
  python pipeline.py --full    # full refresh: borra estado y recarga todo

Cómo funciona el incremental:
  Cada tabla tiene modified_date. dlt lo usa como "cursor": recuerda el
  máximo valor visto en la carga anterior y en la siguiente pide solo
    WHERE modified_date >= <último_valor>
  Con write_disposition="merge" + la primary key (que dlt lee del
  propio Postgres), las filas re-extraídas o actualizadas se upsertean
  en vez de duplicarse. INSERT y UPDATE quedan cubiertos; DELETE no
  (limitación del patrón watermark; para deletes se necesitaría CDC).
"""
import argparse
import dlt
from dlt.sources.sql_database import sql_database

# Conexión de SOLO LECTURA al sistema operacional (mínimo privilegio)
SOURCE_DB = "postgresql://el_reader:el_reader@localhost:5432/happy_scoopers"

# Destinos posibles: el mismo pipeline puede aterrizar en warehouses
# distintos cambiando SOLO esta pieza (ver Anexo B de la guía)
DESTINATIONS = {
    "postgres": lambda: dlt.destinations.postgres(
        "postgresql://dwh:dwh@localhost:5433/happy_scoopers_dwh"
    ),
    "duckdb": lambda: dlt.destinations.duckdb("warehouse.duckdb"),
}

# Las 19 tablas con datos del OLTP (stores e inventory_transactions
# vienen vacías en el repo original; las incluimos igual: si algún día
# reciben datos, viajarán solos)
TABLES = [
    # Esta lista crece laboratorio a laboratorio.
    # Lab 2: "payment_types"
    # Lab 3: + "countries", "provinces", "cities", "addresses"
    # Lab 4: + "products", "product_subcategories",
    #          "product_categories", "product_departments", "units_of_measure"
    # Lab 5: + "customers", "employees", "promotions"
    # Lab 6: + "orders", "order_lines", "package_types"
]


def build_source():
    src = sql_database(
        credentials=SOURCE_DB,
        schema="oltp",
        table_names=TABLES,
    )
    # Cada tabla se carga incrementalmente usando modified_date como cursor
    for name in TABLES:
        src.resources[name].apply_hints(
            write_disposition="merge",  # upsert por primary key (reflejada de la BD)
            incremental=dlt.sources.incremental("modified_date"),
        )
    return src


def main():
    parser = argparse.ArgumentParser(description="EL: oltp -> dwh.raw")
    parser.add_argument("--full", action="store_true",
                        help="full refresh: descarta estado y tablas, recarga todo")
    parser.add_argument("--dest", choices=DESTINATIONS, default="postgres",
                        help="warehouse destino (default: postgres)")
    args = parser.parse_args()

    pipeline = dlt.pipeline(
        pipeline_name=f"happy_scoopers_el_{args.dest}",  # estado separado por destino
        destination=DESTINATIONS[args.dest](),
        dataset_name="raw",          # schema de aterrizaje en el dwh
    )

    load_info = pipeline.run(
        build_source(),
        refresh="drop_sources" if args.full else None,
    )

    # Resumen: cuántas filas viajaron por tabla en ESTA ejecución
    counts = pipeline.last_trace.last_normalize_info.row_counts
    moved = {t: n for t, n in sorted(counts.items())
             if not t.startswith("_dlt") and n > 0}
    print("\n=== Filas transferidas en esta carga ===")
    if moved:
        for t, n in moved.items():
            print(f"  {t:26s} {n:>8,}")
        print(f"  {'TOTAL':26s} {sum(moved.values()):>8,}")
    else:
        print("  (nada nuevo: la fuente no cambió desde la última carga)")
    print(f"\nLoad id: {load_info.loads_ids}")


if __name__ == "__main__":
    main()
