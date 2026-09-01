CREATE TABLE payment_attempts (
    id                  BIGINT PRIMARY KEY AUTO_INCREMENT,
    idempotency_key     VARCHAR(255) COLLATE utf8mb4_bin NOT NULL,
    request_fingerprint CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    amount_jpy          BIGINT NOT NULL,
    status              VARCHAR(20) NOT NULL,
    external_payment_id VARCHAR(255) NULL,
    created_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT uk_payment_attempts_idempotency_key UNIQUE (idempotency_key),
    CONSTRAINT chk_payment_attempts_amount_positive CHECK (amount_jpy > 0),
    CONSTRAINT chk_payment_attempts_status CHECK (
        status IN ('PENDING', 'SUCCESS', 'DECLINED', 'FAILED', 'TIMEOUT')
    )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
