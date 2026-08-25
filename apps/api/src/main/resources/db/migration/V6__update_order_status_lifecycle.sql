UPDATE orders
SET status = 'PREPARING'
WHERE status = 'CONFIRMED';

ALTER TABLE orders
    ADD CONSTRAINT chk_orders_status
        CHECK (status IN ('PENDING', 'PREPARING', 'SHIPPED', 'DELIVERED', 'CANCELLED'));
