{#- ============================================================
    Macros cross-database (Anexo B): la solución profesional a
    "esta función no existe en aquel motor". adapter.dispatch
    elige la implementación según el adaptador activo; default__
    es Postgres (y cualquier motor con to_char), duckdb__ usa las
    funciones nativas de DuckDB. Agregar un motor nuevo = agregar
    macros snowflake__/synapse__ SIN tocar los modelos.
   ============================================================ -#}

{% macro month_name(col) %}{{ return(adapter.dispatch('month_name', 'happy_scoopers')(col)) }}{% endmacro %}
{% macro default__month_name(col) %}trim(to_char({{ col }}, 'Month')){% endmacro %}
{% macro duckdb__month_name(col) %}monthname({{ col }}){% endmacro %}

{% macro month_name_short(col) %}{{ return(adapter.dispatch('month_name_short', 'happy_scoopers')(col)) }}{% endmacro %}
{% macro default__month_name_short(col) %}to_char({{ col }}, 'Mon'){% endmacro %}
{% macro duckdb__month_name_short(col) %}strftime({{ col }}, '%b'){% endmacro %}

{% macro weekday_name(col) %}{{ return(adapter.dispatch('weekday_name', 'happy_scoopers')(col)) }}{% endmacro %}
{% macro default__weekday_name(col) %}trim(to_char({{ col }}, 'Day')){% endmacro %}
{% macro duckdb__weekday_name(col) %}dayname({{ col }}){% endmacro %}

{% macro weekday_name_short(col) %}{{ return(adapter.dispatch('weekday_name_short', 'happy_scoopers')(col)) }}{% endmacro %}
{% macro default__weekday_name_short(col) %}to_char({{ col }}, 'Dy'){% endmacro %}
{% macro duckdb__weekday_name_short(col) %}strftime({{ col }}, '%a'){% endmacro %}

{% macro year_month(col) %}{{ return(adapter.dispatch('year_month', 'happy_scoopers')(col)) }}{% endmacro %}
{% macro default__year_month(col) %}to_char({{ col }}, 'YYYY-MM'){% endmacro %}
{% macro duckdb__year_month(col) %}strftime({{ col }}, '%Y-%m'){% endmacro %}

{#- date_key YYYYMMDD como entero, 100% portable: pura aritmética -#}
{% macro date_key(col) -%}
(extract(year from {{ col }})::int * 10000
 + extract(month from {{ col }})::int * 100
 + extract(day from {{ col }})::int)
{%- endmacro %}
