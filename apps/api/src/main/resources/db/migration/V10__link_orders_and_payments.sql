-- Checkout orchestration: link a payment attempt to the order it reserved, and
-- introduce the reserved order state.
--
-- PAYMENT_PENDING is a new state that sits before PENDING. The meaning of
-- existing PENDING rows is unchanged -- they were, and remain, paid orders
-- awaiting handling -- so no data migration is required.

ALTER TABLE orders
    DROP CONSTRAINT chk_orders_status;

ALTER TABLE orders
    ADD CONSTRAINT chk_orders_status
        CHECK (status IN (
            'PAYMENT_PENDING', 'PENDING', 'PREPARING', 'SHIPPED', 'DELIVERED', 'CANCELLED'
        ));

-- Nullable so the column can be added without rewriting history. Attempts
-- created by the checkout flow always carry an order id.
ALTER TABLE payment_attempts
    ADD COLUMN order_id BIGINT NULL,
    ADD CONSTRAINT fk_payment_attempts_order
        FOREIGN KEY (order_id) REFERENCES orders (id);

-- Reconciliation lookup: a charge that succeeded while its order was never
-- finalised is the one state an operator must be able to find.
CREATE INDEX idx_payment_attempts_status_order
    ON payment_attempts (status, order_id);
