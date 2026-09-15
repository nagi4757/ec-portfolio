-- Refunds are tracked separately from charges.
--
-- A charge is attempted once and settles once; a refund for that charge may be
-- attempted repeatedly and carries its own provider reference. Folding refund
-- states into payment_attempts would also break the invariants already enforced
-- there -- the status CHECK and "SUCCESS implies an external payment id" -- and
-- would pollute the reconciliation query that looks for a successful charge
-- against an unfinalised order.

-- Both halves are one ALTER rather than a DROP followed by an ADD. MariaDB does not
-- roll DDL back, so a failure between two separate statements would leave the table
-- with no status constraint at all and the migration half-applied. Same form as V11,
-- verified on MariaDB 10.11: accepted, leaves exactly one constraint of that name,
-- and the new value set takes effect immediately.
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
            'REFUND_PENDING',
            'SHIPPED',
            'DELIVERED',
            'CANCELLED'
        ));

CREATE TABLE refund_attempts (
    id                  BIGINT PRIMARY KEY AUTO_INCREMENT,
    idempotency_key     VARCHAR(255) COLLATE utf8mb4_bin NOT NULL,
    request_fingerprint CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    order_id            BIGINT NOT NULL,
    payment_attempt_id  BIGINT NOT NULL,
    amount_jpy          BIGINT NOT NULL,
    status              VARCHAR(20) NOT NULL,
    external_refund_id  VARCHAR(255) NULL,
    -- Where the order was before the refund started. A refused refund has to put
    -- it back exactly there rather than guessing a paid state.
    order_status_before VARCHAR(20) NOT NULL,
    created_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT uk_refund_attempts_idempotency_key UNIQUE (idempotency_key),
    CONSTRAINT fk_refund_attempts_order
        FOREIGN KEY (order_id) REFERENCES orders (id),
    CONSTRAINT fk_refund_attempts_payment_attempt
        FOREIGN KEY (payment_attempt_id) REFERENCES payment_attempts (id),
    CONSTRAINT chk_refund_attempts_amount_positive CHECK (amount_jpy > 0),
    CONSTRAINT chk_refund_attempts_status CHECK (
        status IN ('PENDING', 'REFUNDED', 'FAILED', 'UNKNOWN')
    ),
    -- A refund we cannot point at is a refund we cannot reconcile.
    CONSTRAINT chk_refund_attempts_refunded_has_external_id CHECK (
        status <> 'REFUNDED'
        OR (external_refund_id IS NOT NULL AND TRIM(external_refund_id) <> '')
    )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Reconciliation lookup: money returned while the order never left REFUND_PENDING.
CREATE INDEX idx_refund_attempts_status_order
    ON refund_attempts (status, order_id);
