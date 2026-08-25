ALTER TABLE products
    ADD COLUMN active BOOLEAN NOT NULL DEFAULT TRUE,
    ADD CONSTRAINT chk_products_active_boolean
        CHECK (active IN (FALSE, TRUE));

ALTER TABLE order_items
    ADD INDEX idx_order_items_product_id (product_id),
    ADD CONSTRAINT fk_order_items_product
        FOREIGN KEY (product_id) REFERENCES products (id)
        ON DELETE RESTRICT;
