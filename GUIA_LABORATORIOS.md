# Guía de Laboratorios — Happy Scoopers DW
## Construcción incremental: una dimensión a la vez

> Vas a construir un data warehouse dimensional **una dimensión a la
> vez**. Cada laboratorio agrega un concepto nuevo y reutiliza lo
> anterior. Empieza por el arranque del README y sigue el Lab 0.


---

## Mapa del curso

| Lab | Construye | Concepto nuevo | Objetos que toca |
|---|---|---|---|
| 0 | (nada) | El entorno y el modelo en papel | — |
| 1 | `dim_date` | Modelo dbt y materialización | `marts` |
| 2 | `dim_payment_type` | La cadena completa EL → staging → mart | `raw` → `staging` → `marts` |
| 3 | `dim_location` | Desnormalizar una jerarquía (joins) | + `intermediate` |
| 4 | `dim_product` | **SCD Tipo 2** (snapshots) | + `snapshots` |
| 5 | `dim_customer`, `dim_employee`, `dim_promotion` | Práctica autónoma | (los mismos) |
| 6 | `fct_sales` | El hecho: grano, lookups, medidas | `marts` |
| 7 | carga incremental | `is_incremental()` y el ciclo completo | (los mismos) |
| 8 | tests, docs, BI | Calidad y entrega | — |

**Curva de dificultad deliberada:** los labs 1–3 traen cada tecla; el 4 y
5 dan lo esencial y piden completar; del 6 en adelante dan la
especificación y el alumno construye.

---


# LAB 0 — El terreno y el modelo en papel

**Objetivo.** Entender qué hay en la fuente y decidir el modelo
dimensional. Sin escribir código todavía.

**Actividades:**

1. Explorar el OLTP con pgAdmin (`localhost:5050`): las 21 tablas, sus
   relaciones, dónde vive cada cosa.
2. Aplicar los **cuatro pasos de Kimball** en la pizarra:
   - Proceso de negocio → *la venta de helados*
   - Grano → *una línea de pedido*
   - Dimensiones → *fecha, producto, cliente, empleado, ubicación, forma
     de pago, promoción*
   - Hechos → *cantidad, precio, descuento, totales con y sin IVA*
3. Dibujar la estrella en papel.

**Consultas de exploración:**

```sql
-- ¿Cuántas filas tiene cada tabla?
SELECT relname, n_live_tup FROM pg_stat_user_tables
WHERE schemaname='oltp' ORDER BY n_live_tup DESC;

-- La jerarquía de producto, normalizada en 4 tablas
SELECT p.product_name, s.subcategory_name, c.category_name, d.name
FROM oltp.products p
JOIN oltp.product_subcategories s ON s.product_subcategory_id = p.subcategory_id
JOIN oltp.product_categories c    ON c.category_id = s.product_category_id
JOIN oltp.product_departments d   ON d.department_id = c.department_id
LIMIT 5;
```

**Pregunta clave para la discusión:** esa última consulta necesita 3
joins para responder *"¿qué departamento vende más?"*. ¿Qué pasaría con
un millón de líneas de pedido y 20 usuarios preguntando a la vez?

---

# LAB 1 — `dim_date`: el primer modelo

**Concepto nuevo:** qué es un modelo dbt y qué hace una materialización.

**Por qué esta dimensión primero:** no depende de la fuente. No hay
extracción, no hay staging, no hay joins. Un archivo `.sql` y aparece una
tabla en `marts`. Es el "hola mundo" de dbt.

### Manos a la obra

Crear `transform/models/marts/dim_date.sql`:

```sql
with spine as (
    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="cast('2017-01-01' as date)",
        end_date="cast('2028-01-01' as date)"
    ) }}
),

enriched as (
    select
        to_char(date_day, 'YYYYMMDD')::int     as date_key,
        date_day::date                         as date_actual,
        extract(year from date_day)::int       as year,
        extract(quarter from date_day)::int    as quarter,
        extract(month from date_day)::int      as month,
        trim(to_char(date_day, 'Month'))       as month_name,
        extract(day from date_day)::int        as day,
        extract(isodow from date_day)::int     as weekday,
        trim(to_char(date_day, 'Day'))         as weekday_name,
        extract(isodow from date_day) in (6,7) as is_weekend
    from spine
)

select * from enriched
union all
select -1, null, null, null, null, 'N/A', null, null, 'Unknown', false
```

### Ejecutar

```bash
cd transform && dbt run --select dim_date
```

### Verificar

```sql
SELECT count(*) FROM marts.dim_date;                     -- ~4019
SELECT * FROM marts.dim_date WHERE date_key = 20260720;
SELECT * FROM marts.dim_date WHERE date_key = -1;        -- la fila Unknown
```

### Preguntas de comprensión

1. ¿En qué esquema apareció la tabla y quién decidió que fuera `marts`?
   *(Respuesta: `dbt_project.yml`, sección `models:`)*
2. ¿Por qué `date_key` es un entero `YYYYMMDD` y no la fecha misma?
3. ¿Para qué sirve la fila con `date_key = -1`?

### Comparación con SQL Server

Ana dedica un script T-SQL extenso a poblar `Dim_Date` con bucles y
`DATEADD`. Aquí `dbt_utils.date_spine` genera el calendario y el resto
son funciones de fecha. Y de paso corregimos su typo: `Quater` → `quarter`.

---

# LAB 2 — `dim_payment_type`: la cadena completa

**Concepto nuevo:** el viaje entero de un dato — extracción con dlt,
declaración de la fuente, modelo de staging, modelo de dimensión.

**Por qué esta dimensión:** son 4 filas y 2 columnas. La tabla más
tonta del OLTP — justamente para que el foco esté en el **flujo**, no en
los datos.

### Paso 1 — Extraer (dlt)

En `el/pipeline.py`:

```python
TABLES = ["payment_types"]
```

```bash
make el-full
```

Verificar que aterrizó:

```sql
SELECT * FROM raw.payment_types;
```

**Discusión:** ¿qué columnas nuevas aparecieron que no estaban en el
OLTP? *(Las `_dlt_*`: la bitácora de la carga.)*

### Paso 2 — Declarar la fuente

`transform/models/staging/_sources.yml`:

```yaml
version: 2
sources:
  - name: raw
    database: happy_scoopers_dwh
    schema: raw
    tables:
      - name: payment_types
```

### Paso 3 — Staging

`transform/models/staging/stg_payment_types.sql`:

```sql
with source as (
    select * from {{ source('raw', 'payment_types') }}
),
renamed as (
    select
        payment_type_id,
        payment_type_name,
        modified_date
    from source
)
select * from renamed
```

### Paso 4 — La dimensión

`transform/models/marts/dim_payment_type.sql`:

```sql
select
    {{ dbt_utils.generate_surrogate_key(['payment_type_id']) }} as payment_type_key,
    payment_type_id,
    payment_type_name
from {{ ref('stg_payment_types') }}
union all
select '-1', -1, 'Unknown'
```

```bash
cd transform && dbt run
```

### Verificar

```sql
SELECT * FROM staging.stg_payment_types;   -- ¿es vista o tabla?
SELECT * FROM marts.dim_payment_type;      -- 5 filas: 4 + Unknown
```

### Preguntas de comprensión

1. Recorre el dato "Cash" por los tres esquemas. ¿Dónde está físico y
   dónde es solo una vista?
2. ¿Qué diferencia hay entre `payment_type_id` y `payment_type_key`?
   ¿Por qué necesitamos las dos?
3. ¿Qué pasa si borras `stg_payment_types.sql` y corres `dbt run`?
   *(Falla `dim_payment_type`: dbt conoce la dependencia por el `ref()`.)*

### Comparación con SQL Server

Aquí Ana necesitaría `Staging_PaymentType`, `Load_StagingPaymentType`,
`Load_DimPaymentType` y una tarea SSIS. Son 3 archivos de texto contra 4
objetos de base más un paquete binario.

---

# LAB 3 — `dim_location`: desnormalizar una jerarquía

**Concepto nuevo:** la capa `intermediate` y el aplanado de jerarquías.

**Por qué esta dimensión:** la geografía vive normalizada en 4 tablas
encadenadas (`addresses → cities → provinces → countries`). Es el ejemplo
clásico de desnormalización de Kimball.

### Paso 1 — Extraer las cuatro tablas

```python
TABLES = ["payment_types",
          "countries", "provinces", "cities", "addresses"]
```

```bash
make el
```

**Observación para la clase:** solo viajaron las tablas nuevas. Las
`payment_types` no se volvieron a traer.

### Paso 2 — Cuatro modelos de staging

Uno por tabla, todos con el mismo patrón del Lab 2. *(Se deja como
ejercicio: son mecánicos.)*

### Paso 3 — El aplanado (intermediate)

`transform/models/intermediate/int_locations_flattened.sql`:

```sql
select
    a.address_id,
    a.address_line1,
    a.postal_code,
    ci.city_name,
    p.province_name,
    co.country_name,
    co.continent
from {{ ref('stg_addresses') }} a
join {{ ref('stg_cities') }}    ci on ci.city_id     = a.city_id
join {{ ref('stg_provinces') }} p  on p.province_id  = ci.province_id
join {{ ref('stg_countries') }} co on co.country_id  = p.country_id
```

### Paso 4 — La dimensión

```sql
select
    {{ dbt_utils.generate_surrogate_key(['address_id']) }} as location_key,
    address_id, address_line1, postal_code,
    city_name, province_name, country_name, continent
from {{ ref('int_locations_flattened') }}
union all
select '-1', -1, 'Unknown', 'N/A', 'Unknown', 'Unknown', 'Unknown', 'Unknown'
```

### Verificar

```sql
-- Una dirección con TODA su jerarquía en una fila
SELECT * FROM marts.dim_location WHERE address_id = 5777;

-- El valor del aplanado: sin joins para el usuario final
SELECT country_name, count(*) FROM marts.dim_location
GROUP BY 1 ORDER BY 2 DESC LIMIT 5;
```

### Preguntas de comprensión

1. ¿Por qué el aplanado va en `intermediate` y no dentro de
   `stg_addresses`? *(Regla: staging nunca hace joins.)*
2. Si mañana corrigen el nombre de una ciudad en el OLTP, ¿qué pasa con
   las ventas históricas de esa ciudad? *(Se corrigen también: es SCD1.
   ¿Está bien? Discutir.)*
3. ¿Cuántas tablas tendría que unir un usuario de BI para el mismo
   reporte, si consultara el OLTP directo?

---

# LAB 4 — `dim_product`: SCD Tipo 2

**Concepto nuevo:** historia de cambios con snapshots. **El lab más
importante del curso.**

**Por qué esta dimensión:** el precio cambia. Y si cambia, las ventas
pasadas deben seguir valuadas al precio de su época.

### Paso 1 — Extraer

```python
TABLES = [..., "products", "product_subcategories",
               "product_categories", "product_departments",
               "units_of_measure"]
```

### Paso 2 — Staging

Cinco modelos `stg_*`, patrón conocido. *(Ejercicio.)*

### Paso 3 — El snapshot: aquí nace la historia

`transform/snapshots/snapshots.yml`:

```yaml
snapshots:
  - name: snap_products
    relation: ref('stg_products')
    config:
      schema: snapshots
      unique_key: product_id
      strategy: timestamp
      updated_at: modified_date
```

```bash
cd transform && dbt snapshot
```

```sql
SELECT product_id, unit_price, dbt_valid_from, dbt_valid_to
FROM snapshots.snap_products LIMIT 5;
```

**Todas las filas tienen `dbt_valid_to = NULL`**: es la primera foto,
todo es "vigente". Todavía no hay historia — hay un punto de partida.

### Paso 4 — Provocar un cambio

```bash
make simulate      # sube 10% el precio de un producto al azar
make el            # traerlo al warehouse
cd transform && dbt snapshot
```

```sql
SELECT product_id, unit_price, dbt_valid_from::date, dbt_valid_to::date
FROM snapshots.snap_products
WHERE product_id IN (SELECT product_id FROM snapshots.snap_products
                     GROUP BY product_id HAVING count(*) > 1);
```

**Dos filas para el mismo producto.** Ahí está el SCD2. Ver el Anexo B
para el SQL exacto que dbt generó (es el mismo `UPDATE` + `INSERT` del
procedimiento de Ana).

### Paso 5 — Aplanar e ir a la dimensión

El `intermediate` lee del **snapshot**, no del staging:

```sql
select sp.product_id, sp.product_name, sp.unit_price,
       sc.subcategory_name, c.category_name, d.department_name,
       sp.dbt_valid_from, sp.dbt_valid_to
from {{ ref('snap_products') }} sp
join {{ ref('stg_product_subcategories') }} sc on ...
join {{ ref('stg_product_categories') }}    c  on ...
join {{ ref('stg_product_departments') }}   d  on ...
```

Y la dimensión traduce las columnas de dbt al vocabulario de Kimball:

```sql
with versions as (
    select *, row_number() over (partition by product_id
                                 order by dbt_valid_from) as version_n
    from {{ ref('int_products_flattened') }}
)
select
    {{ dbt_utils.generate_surrogate_key(['product_id','dbt_valid_from']) }} as product_key,
    product_id, product_name, subcategory_name, category_name, department_name,
    unit_price,
    case when version_n = 1 then '1900-01-01'::timestamp
         else dbt_valid_from end                    as valid_from,
    coalesce(dbt_valid_to, '9999-12-31'::timestamp) as valid_to,
    (dbt_valid_to is null)                          as is_current
from versions
union all
select '-1', -1, 'Unknown', 'Unknown', 'Unknown', 'Unknown', null,
       '1900-01-01', '9999-12-31', true
```

### Preguntas de comprensión

1. ¿Por qué la clave sustituta incluye `dbt_valid_from` y no solo
   `product_id`?
2. ¿Qué pasaría si quitáramos el `case when version_n = 1`?
   *(Las ventas anteriores a la primera captura no encontrarían versión
   vigente → caerían en Unknown. Probarlo y verlo.)*
3. `dim_location` es SCD1 y `dim_product` SCD2. ¿Quién decide eso y con
   qué criterio?

### Comparación con SQL Server

Siete líneas de YAML contra: tabla de staging, tabla de dimensión,
`IncrementalLoads`, `Lineage`, dos procedimientos y una tarea SSIS.
Y el SQL que dbt genera es **el mismo** que escribe Ana a mano.

---

# LAB 5 — Práctica autónoma: tres dimensiones más

Ya conocen todos los patrones. Ahora los aplican solos.

| Dimensión | Patrón | Dificultad extra |
|---|---|---|
| `dim_customer` | SCD2 (como producto) | Usa `dim_location` para la dirección |
| `dim_employee` | SCD2 + jerarquía | `manager_id` es auto-referencial |
| `dim_promotion` | SCD1 (como payment_type) | La fila `-1` se llama **"Sin promoción"**, no "Unknown" |

**Entregable:** las tres dimensiones construidas y una tabla que
justifique, para cada una, por qué eligieron SCD1 o SCD2.

**Punto de discusión para el cierre:** ¿por qué `dim_promotion` merece
una etiqueta distinta en su fila `-1`? *(Porque una venta sin promoción
no es un dato faltante: es una venta a precio de lista. Mismo mecanismo,
significado opuesto.)*

---

# LAB 6 — `fct_sales`: el hecho

**Concepto nuevo:** el grano, los lookups por vigencia y las medidas.

### Especificación (que el alumno implemente)

- **Grano:** una fila = una línea de pedido.
- **Fuentes:** `stg_orders` + `stg_order_lines`.
- **Claves:** una por dimensión, resueltas con `left join` + `coalesce(..., '-1')`.
- **Lookup SCD2:** para cliente, producto y empleado, elegir la versión
  vigente **en la fecha del pedido**:
  ```sql
  left join {{ ref('dim_product') }} dp
         on dp.product_id = b.product_id
        and b.order_date >= dp.valid_from
        and b.order_date <  dp.valid_to
  ```
- **Medidas:**
  ```
  total_excluding_vat = cantidad * precio * (1 - descuento)
  vat_amount          = total_excluding_vat * tasa_iva
  total_including_vat = suma de los dos
  ```
- **Dimensiones degeneradas:** `order_id`, `line_number`, `description`.

### Verificar

```sql
-- ¿Cuántas ventas caen en la fila Unknown de cada dimensión?
SELECT count(*) FILTER (WHERE customer_key='-1') AS cliente_desconocido,
       count(*) FILTER (WHERE promotion_key='-1') AS sin_promocion,
       count(*) AS total
FROM marts.fct_sales;

-- La prueba de fuego del SCD2
SELECT d.unit_price, count(*), min(dd.date_actual), max(dd.date_actual)
FROM marts.fct_sales f
JOIN marts.dim_product d ON d.product_key = f.product_key
JOIN marts.dim_date dd   ON dd.date_key   = f.order_date_key
WHERE d.product_id = 14 GROUP BY 1;
```

**Pregunta clave:** las ventas viejas del producto 14, ¿aparecen con el
precio viejo o el nuevo? ¿Por qué?

---

# LAB 7 — Carga incremental

**Concepto nuevo:** procesar solo lo nuevo, en las dos puntas.

1. Convertir `fct_sales` a `materialized='incremental'` con
   `unique_key` y filtro `is_incremental()`.
2. Ejecutar el ciclo completo y **leer los números**:

```bash
make simulate
make cycle
```

- dlt: ~40 filas transferidas de 181.000.
- snapshot: `INSERT 0 20` en clientes, `INSERT 0 1` en productos.
- dbt: `MERGE 15` en `fct_sales`, no 2.400.

3. Comparar con `make cycle-full` (reconstrucción total) y medir tiempos.

**Discusión de cierre:** ¿dónde vive el "hasta dónde llegué la última
vez"? *(En dos lugares distintos: el estado de dlt para la extracción, y
el propio fact para la transformación. Ninguno es una tabla que
mantengamos a mano.)*

---

# LAB 8 — Calidad, documentación y entrega

1. **Tests**: `unique` y `not_null` en cada clave; `relationships` entre
   fact y dimensiones. Descubrir los 11 clientes sucios y decidir qué
   hacer con ellos (ver Anexo A).
2. **Documentación**: `dbt docs generate && dbt docs serve` → navegar el
   grafo de linaje y encontrar todo lo que construyeron.
3. **BI**: conectar Metabase con el rol `bi_reader` y armar un tablero:
   ventas por departamento, por país y por mes.

**Entregable final:** el tablero, más un documento de una página que
explique el modelo dimensional a alguien que no sabe SQL.

---

## Apéndice — Errores frecuentes y qué enseñan

| Error del alumno | Qué enseña |
|---|---|
| Crea el modelo fuera de `models/` | dbt solo mira las rutas declaradas en `dbt_project.yml` |
| Su dimensión sale como vista y no como tabla | La carpeta **es** configuración |
| `dbt run` no encuentra la fuente | Falta correr el EL: dbt no extrae, solo transforma |
| Hace joins en staging | Staging es 1:1 con la fuente, por disciplina |
| Olvida la fila `-1` | El fact queda con claves nulas y los reportes pierden filas |
| Su SCD2 manda todo a Unknown | Falta el ajuste `1900-01-01` de la primera versión |
| Edita `raw` a mano para "arreglar" datos | Raw es una fotografía; los arreglos van en marts |
