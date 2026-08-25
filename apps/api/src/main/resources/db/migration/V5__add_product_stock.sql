ALTER TABLE products
    ADD COLUMN stock_quantity INT NOT NULL DEFAULT 0,
    ADD CONSTRAINT chk_products_stock_quantity_non_negative
        CHECK (stock_quantity >= 0);
