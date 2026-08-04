-- ============================================================
-- Simulador de actividad en el OLTP
-- Ejecútalo cuando quieras generar "cambios nuevos" para probar
-- la extracción/carga INCREMENTAL del pipeline:
--
--   docker exec -i happy_scoopers_oltp \
--     psql -U postgres -d happy_scoopers < tools/simulate_activity.sql
--
-- Genera:
--   * 5 pedidos nuevos con 1-3 líneas cada uno (INSERT)
--   * 20 clientes con teléfono actualizado        (UPDATE -> SCD2)
--   * 1 producto con cambio de precio             (UPDATE -> SCD2)
-- Todo con modified_date = now(), que es el watermark incremental.
-- ============================================================
SET search_path TO oltp;

BEGIN;

-- 1) Pedidos nuevos ------------------------------------------------
WITH nuevos AS (
    INSERT INTO orders (customer_id, employee_id, delivery_address_id,
                        payment_type_id, order_date, delivery_date,
                        comments, status, modified_date)
    SELECT c.customer_id,
           e.employee_id,
           c.delivery_address_id,
           1 + floor(random() * 4)::int,
           now(),
           now() + interval '2 days',
           'Pedido simulado',
           3,
           now()
    FROM (SELECT customer_id, delivery_address_id
          FROM customers
          WHERE delivery_address_id > 0
          ORDER BY random() LIMIT 5) c
    CROSS JOIN LATERAL (SELECT employee_id FROM employees
                        ORDER BY random() LIMIT 1) e
    RETURNING order_id
)
INSERT INTO order_lines (order_id, product_id, package_type_id,
                         unit_price, description, quantity, discount,
                         modified_date, line_number, vat_rate)
SELECT n.order_id,
       p.product_id,
       1 + floor(random() * 14)::int,
       p.unit_price,
       p.product_name,
       1 + floor(random() * 5)::int,
       0,
       now(),
       gs::text,
       0.20
FROM nuevos n
CROSS JOIN generate_series(1, 1 + floor(random() * 3)::int) gs
CROSS JOIN LATERAL (SELECT product_id, product_name, unit_price
                    FROM products ORDER BY random() LIMIT 1) p;

-- 2) Clientes actualizados (dispara SCD tipo 2 en la dimensión) ----
UPDATE customers
SET phone_number  = '555-' || lpad(floor(random() * 10000)::text, 4, '0'),
    modified_date = now()
WHERE customer_id IN (SELECT customer_id FROM customers ORDER BY random() LIMIT 20);

-- 3) Cambio de precio de un producto (SCD tipo 2) ------------------
UPDATE products
SET unit_price    = round((unit_price * 1.10)::numeric, 2),
    modified_date = now()
WHERE product_id = (SELECT product_id FROM products ORDER BY random() LIMIT 1);

COMMIT;

SELECT 'orders nuevos'      AS que, count(*) FROM orders      WHERE modified_date > now() - interval '1 minute'
UNION ALL
SELECT 'order_lines nuevas',        count(*) FROM order_lines WHERE modified_date > now() - interval '1 minute'
UNION ALL
SELECT 'customers cambiados',       count(*) FROM customers   WHERE modified_date > now() - interval '1 minute'
UNION ALL
SELECT 'products cambiados',        count(*) FROM products    WHERE modified_date > now() - interval '1 minute';
