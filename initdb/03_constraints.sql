-- ============================================================
-- Constraints e índices (post-carga)
-- El OLTP original en SQL Server NO tenía foreign keys.
-- Aquí las agregamos para documentar el modelo, validadas
-- contra los datos reales, con una excepción conocida:
--   * 11 clientes tienen delivery/billing_address_id = 0
--     (centinela "sin dirección"). Esas 2 FKs van NOT VALID.
--     -> caso ideal para un test relationships en dbt.
-- ============================================================
SET search_path TO oltp;

-- Geografía
ALTER TABLE provinces  ADD CONSTRAINT fk_provinces_country FOREIGN KEY (country_id)  REFERENCES countries (country_id);
ALTER TABLE cities     ADD CONSTRAINT fk_cities_province   FOREIGN KEY (province_id) REFERENCES provinces (province_id);
ALTER TABLE addresses  ADD CONSTRAINT fk_addresses_city    FOREIGN KEY (city_id)     REFERENCES cities (city_id);

-- Personas (NOT VALID: datos sucios conocidos, address_id = 0)
ALTER TABLE customers  ADD CONSTRAINT fk_customers_delivery_addr FOREIGN KEY (delivery_address_id) REFERENCES addresses (address_id) NOT VALID;
ALTER TABLE customers  ADD CONSTRAINT fk_customers_billing_addr  FOREIGN KEY (billing_address_id)  REFERENCES addresses (address_id) NOT VALID;
ALTER TABLE employees  ADD CONSTRAINT fk_employees_address FOREIGN KEY (address_id) REFERENCES addresses (address_id);
ALTER TABLE employees  ADD CONSTRAINT fk_employees_manager FOREIGN KEY (manager_id) REFERENCES employees (employee_id);
ALTER TABLE stores     ADD CONSTRAINT fk_stores_manager    FOREIGN KEY (manager_id) REFERENCES employees (employee_id);
ALTER TABLE stores     ADD CONSTRAINT fk_stores_address    FOREIGN KEY (address_id) REFERENCES addresses (address_id);

-- Catálogo de productos
ALTER TABLE product_categories    ADD CONSTRAINT fk_categories_department FOREIGN KEY (department_id) REFERENCES product_departments (department_id);
ALTER TABLE product_subcategories ADD CONSTRAINT fk_subcategories_category FOREIGN KEY (product_category_id) REFERENCES product_categories (category_id);
ALTER TABLE products   ADD CONSTRAINT fk_products_subcategory FOREIGN KEY (subcategory_id) REFERENCES product_subcategories (product_subcategory_id);
ALTER TABLE products   ADD CONSTRAINT fk_products_uom FOREIGN KEY (unit_of_measure_id) REFERENCES units_of_measure (unit_of_measure_id);

-- Ingredientes e inventario
ALTER TABLE ingredients     ADD CONSTRAINT fk_ingredients_uom FOREIGN KEY (unit_of_measure_id) REFERENCES units_of_measure (unit_of_measure_id);
ALTER TABLE recipes         ADD CONSTRAINT fk_recipes_product FOREIGN KEY (product_id) REFERENCES products (product_id);
ALTER TABLE recipes         ADD CONSTRAINT fk_recipes_ingredient FOREIGN KEY (ingredient_id) REFERENCES ingredients (ingredient_id);
ALTER TABLE inventory_items ADD CONSTRAINT fk_invitems_product FOREIGN KEY (product_id) REFERENCES products (product_id);
ALTER TABLE inventory_items ADD CONSTRAINT fk_invitems_ingredient FOREIGN KEY (ingredient_id) REFERENCES ingredients (ingredient_id);
ALTER TABLE inventory_items ADD CONSTRAINT fk_invitems_package FOREIGN KEY (package_type_id) REFERENCES package_types (package_type_id);
ALTER TABLE inventory_items ADD CONSTRAINT fk_invitems_uom FOREIGN KEY (unit_of_measure_id) REFERENCES units_of_measure (unit_of_measure_id);
ALTER TABLE inventory_transactions ADD CONSTRAINT fk_invtx_item FOREIGN KEY (inventory_item_id) REFERENCES inventory_items (inventory_item_id);
ALTER TABLE inventory_transactions ADD CONSTRAINT fk_invtx_customer FOREIGN KEY (customer_id) REFERENCES customers (customer_id);

-- Transaccional
ALTER TABLE orders      ADD CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES customers (customer_id);
ALTER TABLE orders      ADD CONSTRAINT fk_orders_employee FOREIGN KEY (employee_id) REFERENCES employees (employee_id);
ALTER TABLE orders      ADD CONSTRAINT fk_orders_delivery_addr FOREIGN KEY (delivery_address_id) REFERENCES addresses (address_id);
ALTER TABLE orders      ADD CONSTRAINT fk_orders_payment_type FOREIGN KEY (payment_type_id) REFERENCES payment_types (payment_type_id);
ALTER TABLE order_lines ADD CONSTRAINT fk_orderlines_order FOREIGN KEY (order_id) REFERENCES orders (order_id);
ALTER TABLE order_lines ADD CONSTRAINT fk_orderlines_product FOREIGN KEY (product_id) REFERENCES products (product_id);
ALTER TABLE order_lines ADD CONSTRAINT fk_orderlines_package FOREIGN KEY (package_type_id) REFERENCES package_types (package_type_id);
ALTER TABLE order_lines ADD CONSTRAINT fk_orderlines_promotion FOREIGN KEY (promotion_id) REFERENCES promotions (promotion_id);
ALTER TABLE order_lines ADD CONSTRAINT fk_orderlines_invitem FOREIGN KEY (inventory_item_id) REFERENCES inventory_items (inventory_item_id);

-- Índices para la extracción incremental (watermark sobre modified_date)
CREATE INDEX idx_orders_modified_date      ON orders (modified_date);
CREATE INDEX idx_order_lines_modified_date ON order_lines (modified_date);
CREATE INDEX idx_customers_modified_date   ON customers (modified_date);
CREATE INDEX idx_order_lines_order_id      ON order_lines (order_id);

-- Rol de solo lectura para la herramienta de EL (extracción)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'el_reader') THEN
        CREATE ROLE el_reader LOGIN PASSWORD 'el_reader';
    END IF;
END $$;
GRANT USAGE ON SCHEMA oltp TO el_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA oltp TO el_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA oltp GRANT SELECT ON TABLES TO el_reader;
