package com.nagi4757.ec.api.payment.application

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class PaymentRequestFingerprintTest {
    @Test
    fun `produces a reproducible SHA-256 fingerprint`() {
        val request = chargeRequest(amountJpy = 10_000L, paymentMethodId = "payment-method-日本語")

        val first = PaymentRequestFingerprint.from(request)
        val second = PaymentRequestFingerprint.from(request)

        assertEquals(first, second)
        assertEquals("e0bfb03e05dece5b35a18536a25083ac840d35454ce01721620555afc41e8a90", first)
        assertTrue(Regex("^[0-9a-f]{64}$").matches(first))
    }

    @Test
    fun `changes the fingerprint when amount changes`() {
        val original = chargeRequest(amountJpy = 10_000L, paymentMethodId = "payment-method-1")

        assertNotEquals(
            PaymentRequestFingerprint.from(original),
            PaymentRequestFingerprint.from(original.copy(amountJpy = 10_001L))
        )
    }

    @Test
    fun `changes the fingerprint when payment method changes`() {
        val original = chargeRequest(amountJpy = 10_000L, paymentMethodId = "payment-method-1")

        assertNotEquals(
            PaymentRequestFingerprint.from(original),
            PaymentRequestFingerprint.from(original.copy(paymentMethodId = "payment-method-2"))
        )
    }

    private fun chargeRequest(amountJpy: Long, paymentMethodId: String) = ChargePaymentRequest(
        amountJpy = amountJpy,
        paymentMethodId = paymentMethodId,
        idempotencyKey = "fingerprint-test-key"
    )
}
