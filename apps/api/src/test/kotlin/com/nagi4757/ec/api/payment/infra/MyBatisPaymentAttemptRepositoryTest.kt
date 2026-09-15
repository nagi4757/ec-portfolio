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
            amountJpy = 10_000L,
            orderId = ORDER_ID
        )
        `when`(mapper.insertPaymentAttempt(inserted)).thenReturn(1)
        `when`(mapper.selectByIdempotencyKey(IDEMPOTENCY_KEY)).thenReturn(stored)

        val result = repository.createPending(IDEMPOTENCY_KEY, FINGERPRINT, 10_000L, ORDER_ID)

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
    fun `applies a terminal payment result and reports that it wrote it`() {
        `when`(mapper.updatePaymentAttemptResult(10L, "SUCCESS", "external-1")).thenReturn(1)
        `when`(mapper.selectById(10L)).thenReturn(record(status = "SUCCESS", externalPaymentId = "external-1"))

        val applied = repository.applyResult(10L, PaymentAttemptStatus.SUCCESS, "external-1")

        assertTrue(applied.applied)
        assertEquals(PaymentAttemptStatus.SUCCESS, applied.attempt.status)
        verify(mapper).updatePaymentAttemptResult(10L, "SUCCESS", "external-1")
    }

    @Test
    fun `adopts the stored outcome when another writer already settled the attempt`() {
        // The conditional statement matched nothing, which means a concurrent retry
        // settled this attempt first. Its result is authoritative and must not be
        // overwritten or turned into an error.
        `when`(mapper.updatePaymentAttemptResult(10L, "FAILED", null)).thenReturn(0)
        `when`(mapper.selectById(10L)).thenReturn(record(status = "SUCCESS", externalPaymentId = "external-1"))

        val applied = repository.applyResult(10L, PaymentAttemptStatus.FAILED, null)

        assertFalse(applied.applied)
        assertEquals(PaymentAttemptStatus.SUCCESS, applied.attempt.status)
    }

    @Test
    fun `rejects pending as a payment result`() {
        assertThrows(IllegalArgumentException::class.java) {
            repository.applyResult(10L, PaymentAttemptStatus.PENDING, null)
        }

        verify(mapper, never()).updatePaymentAttemptResult(10L, "PENDING", null)
    }

    private fun record(
        status: String = "PENDING",
        externalPaymentId: String? = null
    ) = PaymentAttemptRecord(
        id = 10L,
        orderId = ORDER_ID,
        externalPaymentId = externalPaymentId,
        idempotencyKey = IDEMPOTENCY_KEY,
        requestFingerprint = FINGERPRINT,
        amountJpy = 10_000L,
        status = status,
        createdAt = LocalDateTime.of(2026, 9, 1, 10, 0),
        updatedAt = LocalDateTime.of(2026, 9, 1, 10, 0)
    )

    private companion object {
        const val ORDER_ID = 55L
        const val IDEMPOTENCY_KEY = "payment-attempt-key"
        const val FINGERPRINT = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
}
