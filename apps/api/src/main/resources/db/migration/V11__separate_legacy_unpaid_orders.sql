-- Orders that predate checkout were created without a payment. PENDING now means
-- "paid, awaiting handling", so leaving them as PENDING would let an operator
-- prepare and ship goods nobody ever paid for, and would make them look eligible
-- for the refund-required cancellation rule.
--
-- They are moved to LEGACY_UNPAID: visible and queryable, but outside the paid
-- lifecycle. They have no payment attempt, so no refund is owed if one is
-- cancelled.
--
-- This runs before the new CHECK is installed so existing rows satisfy it.
UPDATE orders
SET status = 'LEGACY_UNPAID'
WHERE status = 'PENDING'
  AND id NOT IN (
      SELECT order_id FROM payment_attempts WHERE order_id IS NOT NULL
  );

ALTER TABLE orders
    DROP CONSTRAINT chk_orders_status;

ALTER TABLE orders
    ADD CONSTRAINT chk_orders_status
        CHECK (status IN (
            'LEGACY_UNPAID',
            'PAYMENT_PENDING',
            'PENDING',
            'PREPARING',
            'SHIPPED',
            'DELIVERED',
            'CANCELLED'
        ));

-- A successful charge is only meaningful with the provider's reference: without
-- it there is nothing to reconcile against and nothing to refund. Enforced in the
-- database so no code path can record a success that cannot be traced.
ALTER TABLE payment_attempts
    ADD CONSTRAINT chk_payment_attempts_success_has_external_id
        CHECK (
            status <> 'SUCCESS'
            OR (external_payment_id IS NOT NULL AND TRIM(external_payment_id) <> '')
        );
