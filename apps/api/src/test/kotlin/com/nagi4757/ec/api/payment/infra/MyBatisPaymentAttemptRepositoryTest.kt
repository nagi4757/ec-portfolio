package com.nagi4757.ec.api.payment.infra

import com.nagi4757.ec.api.payment.domain.model.PaymentAttemptStatus
import com.nagi4757.ec.api.payment.infra.mapper.PaymentAttemptMapper
import com.nagi4757.ec.api.payment.infra.mapper.PaymentAttemptRecord
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.verify
import org.mockito.Mockito.`when`
import java.time.LocalDateTime

class MyBatisPaymentAttemptRepositoryTest {
    private val mapper = mock(PaymentAttemptMapper::class.java)
    private val repository = MyBatisPaymentAttemptRepository(mapper)

    @Test
    fun `creates and reloads a pending attempt`() {
        val stored = record()
        val inserted = PaymentAttemptRecord(
            idempotencyKey = IDEMPOTENCY_KEY,
            requestFingerprint = FINGERPRINT,
            amountJpy = 10_000L
        )
        `when`(mapper.insertPaymentAttempt(inserted)).thenReturn(1)
        `when`(mapper.selectByIdempotencyKey(IDEMPOTENCY_KEY)).thenReturn(stored)

        val result = repository.createPending(IDEMPOTENCY_KEY, FINGERPRINT, 10_000L)

        verify(mapper).insertPaymentAttempt(inserted)
        assertEquals(PaymentAttemptStatus.PENDING.name, inserted.status)
        assertNull(inserted.externalPaymentId)
        assertEquals(stored.id, result.id)
        assertEquals(PaymentAttemptStatus.PENDING, result.status)
        verify(mapper).selectByIdempotencyKey(IDEMPOTENCY_KEY)
    }

    @Test
    fun `finds an attempt by idempotency key`() {
        `when`(mapper.selectByIdempotencyKey(IDEMPOTENCY_KEY)).thenReturn(record(status = "TIMEOUT"))

        val result = repository.findByIdempotencyKey(IDEMPOTENCY_KEY)

        assertEquals(PaymentAttemptStatus.TIMEOUT, result?.status)
        assertEquals(FINGERPRINT, result?.requestFingerprint)
    }

    @Test
    fun `returns null when an attempt does not exist`() {
        `when`(mapper.selectByIdempotencyKey(IDEMPOTENCY_KEY)).thenReturn(null)

        assertNull(repository.findByIdempotencyKey(IDEMPOTENCY_KEY))
    }

    @Test
    fun `updates a terminal payment result`() {
        `when`(mapper.updatePaymentAttemptResult(10L, "SUCCESS", "external-1")).thenReturn(1)

        assertTrue(repository.updateResult(10L, PaymentAttemptStatus.SUCCESS, "external-1"))
        verify(mapper).updatePaymentAttemptResult(10L, "SUCCESS", "external-1")
    }

    @Test
    fun `reports a missing attempt during result update`() {
        `when`(mapper.updatePaymentAttemptResult(10L, "FAILED", null)).thenReturn(0)

        assertFalse(repository.updateResult(10L, PaymentAttemptStatus.FAILED, null))
    }

    @Test
    fun `rejects pending as a payment result`() {
        assertThrows(IllegalArgumentException::class.java) {
            repository.updateResult(10L, PaymentAttemptStatus.PENDING, null)
        }

        verify(mapper, never()).updatePaymentAttemptResult(10L, "PENDING", null)
    }

    private fun record(status: String = "PENDING") = PaymentAttemptRecord(
        id = 10L,
        idempotencyKey = IDEMPOTENCY_KEY,
        requestFingerprint = FINGERPRINT,
        amountJpy = 10_000L,
        status = status,
        externalPaymentId = null,
        createdAt = LocalDateTime.of(2026, 9, 1, 10, 0),
        updatedAt = LocalDateTime.of(2026, 9, 1, 10, 0)
    )

    private companion object {
        const val IDEMPOTENCY_KEY = "payment-attempt-key"
        const val FINGERPRINT = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
}
