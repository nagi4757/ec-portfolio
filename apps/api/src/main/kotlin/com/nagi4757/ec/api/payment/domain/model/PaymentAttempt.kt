package com.nagi4757.ec.api.payment.domain.model

import java.time.LocalDateTime

data class PaymentAttempt(
    val id: Long?,
    val idempotencyKey: String,
    val requestFingerprint: String,
    val amountJpy: Long,
    val status: PaymentAttemptStatus,
    val externalPaymentId: String?,
    val createdAt: LocalDateTime?,
    val updatedAt: LocalDateTime?
) {
    init {
        require(idempotencyKey.isNotBlank()) { "Idempotency key must not be blank" }
        require(FINGERPRINT_PATTERN.matches(requestFingerprint)) { "Request fingerprint must be a SHA-256 hex value" }
        require(amountJpy > 0) { "Payment amount must be positive" }
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
    TIMEOUT
}
