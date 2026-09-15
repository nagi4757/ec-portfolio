-- Orders that predate checkout were created without a payment. PENDING now means
-- "paid, awaiting handling", so leaving them as PENDING would let an operator
-- prepare and ship goods nobody ever paid for, and would make them look eligible
-- for the refund-required cancellation rule.
--
-- They are moved to LEGACY_UNPAID: visible and queryable, but outside the paid
-- lifecycle. They have no payment attempt, so no refund is owed if one is
-- cancelled.

-- The constraint is widened before any row is rewritten. Writing LEGACY_UNPAID
-- first would violate the CHECK V10 installed, which does not list that value, and
-- the migration would fail on any database that actually holds a legacy order. An
-- empty database hides this: the UPDATE matches nothing and nothing is validated.
--
-- Both halves are one ALTER rather than a DROP followed by an ADD. MariaDB does not
-- roll DDL back, so a failure between two separate statements would leave the table
-- with no status constraint at all and the migration half-applied. Verified on
-- MariaDB 10.11: the combined form is accepted, leaves exactly one constraint of
-- that name, and the new value set takes effect immediately.
--
-- The new set is a superset of the old one, so every existing row stays valid while
-- the constraint is replaced.
ALTER TABLE orders
    DROP CONSTRAINT chk_orders_status,
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

UPDATE orders
SET status = 'LEGACY_UNPAID'
WHERE status = 'PENDING'
  AND id NOT IN (
      SELECT order_id FROM payment_attempts WHERE order_id IS NOT NULL
  );

-- A successful charge is only meaningful with the provider's reference: without
-- it there is nothing to reconcile against and nothing to refund. Enforced in the
-- database so no code path can record a success that cannot be traced.
--
-- Safe to add to the existing table: PaymentGateway was never wired into the
-- application before this change, so no charge has ever been recorded.
ALTER TABLE payment_attempts
    ADD CONSTRAINT chk_payment_attempts_success_has_external_id
        CHECK (
            status <> 'SUCCESS'
            OR (external_payment_id IS NOT NULL AND TRIM(external_payment_id) <> '')
        );
