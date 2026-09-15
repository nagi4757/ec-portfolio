-- One order may have at most one successful charge.
--
-- Refund reads the amount and the provider's payment reference from "the order's
-- settled charge". That phrase only means something if there is at most one, and
-- until now nothing enforced it: order_id carried a foreign key but no uniqueness,
-- so the guarantee was an application convention that a future partial-payment or
-- re-charge feature would quietly break, leaving the refund to reverse whichever
-- row sorted first.
--
-- A plain UNIQUE (order_id) is wrong here: it would also forbid the PENDING,
-- TIMEOUT, DECLINED and FAILED attempts that a legitimate retry produces for the
-- same order. The generated column is NULL for every non-SUCCESS row, and NULLs do
-- not collide in a unique index, so only the SUCCESS rows are constrained.
--
-- Verified on MariaDB 10.11: a second SUCCESS is rejected on INSERT and on UPDATE
-- (promoting a second attempt to SUCCESS), other orders keep their own SUCCESS, and
-- pre-V10 rows with a NULL order_id do not collide with each other.
ALTER TABLE payment_attempts
    ADD COLUMN successful_order_id BIGINT
        AS (CASE WHEN status = 'SUCCESS' THEN order_id ELSE NULL END) VIRTUAL;

ALTER TABLE payment_attempts
    ADD CONSTRAINT uk_payment_attempts_successful_order
        UNIQUE (successful_order_id);

-- Refunds may only start from an order that is paid and still in the warehouse.
-- The application already refuses anything else, and the domain model rejects it
-- when the row is read back; this stops a bad value reaching the column in the
-- first place, so a refused refund can always restore a status that is actually
-- reachable.
ALTER TABLE refund_attempts
    ADD CONSTRAINT chk_refund_attempts_order_status_before
        CHECK (order_status_before IN ('PENDING', 'PREPARING'));
