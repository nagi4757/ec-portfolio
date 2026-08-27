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
    val status: RefundPaymentStatus
)

enum class RefundPaymentStatus {
    REFUNDED,
    REFUND_FAILED
}
