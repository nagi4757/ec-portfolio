package com.nagi4757.ec.api.payment.domain.model

import java.time.LocalDateTime

data class PaymentAttempt(
    val id: Long?,
    val idempotencyKey: String,
    val requestFingerprint: String,
    val amountJpy: Long,
    val status: PaymentAttemptStatus,
    val externalPaymentId: String?,
    val orderId: Long?,
    val createdAt: LocalDateTime?,
    val updatedAt: LocalDateTime?
) {
    init {
        require(idempotencyKey.isNotBlank()) { "Idempotency key must not be blank" }
        require(FINGERPRINT_PATTERN.matches(requestFingerprint)) { "Request fingerprint must be a SHA-256 hex value" }
        require(amountJpy > 0) { "Payment amount must be positive" }
        // A success without the provider's reference cannot be reconciled or
        // refunded, so it is not a success we are willing to record.
        require(status != PaymentAttemptStatus.SUCCESS || !externalPaymentId.isNullOrBlank()) {
            "A successful payment attempt must carry an external payment id"
        }
    }

    private companion object {
        val FINGERPRINT_PATTERN = Regex("^[0-9a-f]{64}$")
    }
}

enum class PaymentAttemptStatus {
    PENDING,
    SUCCESS,
    DECLINED,
    FAILED,
    TIMEOUT;

    /**
     * A terminal attempt is a settled fact and must never be rewritten. A
     * non-terminal one may still be driven to an outcome by a retry, because the
     * gateway is idempotent and replays the original result for the same key.
     */
    fun isTerminal(): Boolean = this == SUCCESS || this == DECLINED || this == FAILED

    fun canTransitionTo(target: PaymentAttemptStatus): Boolean =
        !isTerminal() && target != PENDING
}
