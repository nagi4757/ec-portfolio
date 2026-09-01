package com.nagi4757.ec.api.payment.application

import com.nagi4757.ec.api.payment.domain.model.PaymentAttemptStatus
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class PaymentAttemptStatusMappingTest {
    @Test
    fun `maps provider outcomes to persisted attempt statuses`() {
        val expected = mapOf(
            ChargePaymentStatus.SUCCESS to PaymentAttemptStatus.SUCCESS,
            ChargePaymentStatus.DECLINED to PaymentAttemptStatus.DECLINED,
            ChargePaymentStatus.FAILED to PaymentAttemptStatus.FAILED,
            ChargePaymentStatus.TIMEOUT to PaymentAttemptStatus.TIMEOUT
        )

        expected.forEach { (chargeStatus, attemptStatus) ->
            assertEquals(attemptStatus, chargeStatus.toPersistedAttemptStatus())
        }
    }

    @Test
    fun `does not map duplicate to a persisted attempt status`() {
        assertNull(ChargePaymentStatus.DUPLICATE.toPersistedAttemptStatus())
    }
}
