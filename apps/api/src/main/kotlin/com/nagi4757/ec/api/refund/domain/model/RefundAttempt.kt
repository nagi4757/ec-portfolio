package com.nagi4757.ec.api.refund.domain.model

import com.nagi4757.ec.api.order.domain.model.OrderStatus
import java.time.LocalDateTime

/**
 * One attempt to return the money for an order.
 *
 * Kept apart from the charge attempt: a charge settles once, while a refund may be
 * retried, carries its own provider reference, and is reconciled separately.
 */
data class RefundAttempt(
    val id: Long?,
    val idempotencyKey: String,
    val requestFingerprint: String,
    val orderId: Long,
    val paymentAttemptId: Long,
    val amountJpy: Long,
    val status: RefundAttemptStatus,
    val externalRefundId: String?,
    /** The order status to restore if the refund is refused. */
    val orderStatusBefore: OrderStatus,
    val createdAt: LocalDateTime?,
    val updatedAt: LocalDateTime?
) {
    init {
        require(idempotencyKey.isNotBlank()) { "Idempotency key must not be blank" }
        require(FINGERPRINT_PATTERN.matches(requestFingerprint)) {
            "Request fingerprint must be a SHA-256 hex value"
        }
        require(amountJpy > 0) { "Refund amount must be positive" }
        // A refund without the provider's reference cannot be reconciled against the
        // money that actually moved.
        require(status != RefundAttemptStatus.REFUNDED || !externalRefundId.isNullOrBlank()) {
            "A completed refund must carry an external refund id"
        }
        require(orderStatusBefore.isRefundable()) {
            "A refund may only start from a refundable order status"
        }
    }

    private companion object {
        val FINGERPRINT_PATTERN = Regex("^[0-9a-f]{64}$")
    }
}

enum class RefundAttemptStatus {
    PENDING,
    REFUNDED,
    FAILED,

    /**
     * The provider did not report an outcome. Non-terminal on purpose: the money may
     * already have moved, so the order must not be cancelled, and the same key may
     * be driven again to find out.
     */
    UNKNOWN;

    /** A settled fact that must never be rewritten. */
    fun isTerminal(): Boolean = this == REFUNDED || this == FAILED

    /**
     * PENDING -> REFUNDED | FAILED | UNKNOWN
     * UNKNOWN -> REFUNDED | UNKNOWN
     *
     * UNKNOWN may not become FAILED. Once the provider has failed to tell us what
     * happened, the refund may already have gone through; a later "failed" answer to
     * a duplicate request describes that retry, not the original. Accepting it would
     * put the order back into a paid state while the customer's money is gone.
     *
     * Only a provider contract that can prove the original refund definitively
     * failed would justify reopening this, which is a question for the PAY.JP
     * adapter.
     */
    fun canTransitionTo(target: RefundAttemptStatus): Boolean = when (this) {
        PENDING -> target != PENDING
        UNKNOWN -> target == REFUNDED || target == UNKNOWN
        REFUNDED, FAILED -> false
    }
}
