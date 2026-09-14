package com.nagi4757.ec.api.payment.application

data class ChargePaymentRequest(
    val amountJpy: Long,
    val paymentMethodId: String,
    val idempotencyKey: String
) {
    init {
        require(amountJpy > 0) { "Payment amount must be positive" }
        require(paymentMethodId.isNotBlank()) { "Payment method id must not be blank" }
        require(idempotencyKey.isNotBlank()) { "Idempotency key must not be blank" }
    }
}

data class ChargePaymentResult(
    val status: ChargePaymentStatus,
    val externalPaymentId: String? = null
) {
    val outcomeKnown: Boolean
        get() = status != ChargePaymentStatus.TIMEOUT
}

enum class ChargePaymentStatus {
    SUCCESS,
    DECLINED,
    FAILED,
    TIMEOUT,
    DUPLICATE
}

data class RefundPaymentRequest(
    val externalPaymentId: String,
    val amountJpy: Long,
    val idempotencyKey: String
) {
    init {
        require(externalPaymentId.isNotBlank()) { "External payment id must not be blank" }
        require(amountJpy > 0) { "Refund amount must be positive" }
        require(idempotencyKey.isNotBlank()) { "Idempotency key must not be blank" }
    }
}

data class RefundPaymentResult(
    val status: RefundPaymentStatus,
    /**
     * The provider's reference for the refund. Needed to reconcile the money that
     * went back, and distinct from the charge's own id.
     */
    val externalRefundId: String? = null
) {
    /**
     * False when the provider did not tell us whether the refund happened. Mirrors
     * [ChargePaymentResult.outcomeKnown]: the caller must not treat an unknown
     * outcome as a refusal, because the money may already have been returned.
     */
    val outcomeKnown: Boolean
        get() = status != RefundPaymentStatus.REFUND_UNKNOWN
}

enum class RefundPaymentStatus {
    REFUNDED,
    REFUND_FAILED,

    /**
     * The provider did not report an outcome. Without this, a timeout would be
     * indistinguishable from a refusal, and an order could be left un-cancelled with
     * no way to tell whether a retry is safe.
     */
    REFUND_UNKNOWN
}
