package com.nagi4757.ec.api.payment.infra

import com.nagi4757.ec.api.payment.application.ChargePaymentRequest
import com.nagi4757.ec.api.payment.application.ChargePaymentResult
import com.nagi4757.ec.api.payment.application.ChargePaymentStatus
import com.nagi4757.ec.api.payment.application.RefundPaymentRequest
import com.nagi4757.ec.api.payment.application.RefundPaymentStatus
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertSame
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.Arguments
import org.junit.jupiter.params.provider.MethodSource
import org.junit.jupiter.params.provider.ValueSource
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.stream.Stream

class MockPaymentGatewayTest {
    private val gateway = MockPaymentGateway()

    @ParameterizedTest
    @MethodSource("chargeScenarios")
    fun `returns deterministic charge scenarios`(
        paymentMethodId: String,
        expectedStatus: ChargePaymentStatus
    ) {
        val result = gateway.charge(chargeRequest(paymentMethodId, "charge-$expectedStatus"))

        assertEquals(expectedStatus, result.status)
        assertEquals(expectedStatus != ChargePaymentStatus.TIMEOUT, result.outcomeKnown)
        if (expectedStatus == ChargePaymentStatus.SUCCESS) {
            assertEquals("mock-payment:charge-SUCCESS", result.externalPaymentId)
        } else {
            assertNull(result.externalPaymentId)
        }
    }

    @Test
    fun `replays the original charge result for the same idempotency key and request`() {
        val request = chargeRequest(MOCK_SUCCESS_PAYMENT_METHOD, "same-charge-key")

        val first = gateway.charge(request)
        val replay = gateway.charge(request)

        assertSame(first, replay)
        assertEquals(ChargePaymentStatus.SUCCESS, replay.status)
    }

    @Test
    fun `returns duplicate without replacing the original charge for a reused key with different input`() {
        val original = chargeRequest(MOCK_SUCCESS_PAYMENT_METHOD, "conflicting-charge-key")
        val conflicting = original.copy(amountJpy = original.amountJpy + 1)

        assertEquals(ChargePaymentStatus.SUCCESS, gateway.charge(original).status)
        assertEquals(ChargePaymentStatus.DUPLICATE, gateway.charge(conflicting).status)
        assertEquals(ChargePaymentStatus.SUCCESS, gateway.charge(original).status)
    }

    @Test
    fun `keeps timeout outcome unknown when replayed`() {
        val request = chargeRequest(MOCK_TIMEOUT_PAYMENT_METHOD, "timeout-key")

        val first = gateway.charge(request)
        val replay = gateway.charge(request)

        assertFalse(first.outcomeKnown)
        assertFalse(replay.outcomeKnown)
        assertSame(first, replay)
    }

    @Test
    fun `returns refunded deterministically`() {
        val result = gateway.refund(refundRequest(MOCK_REFUNDED_PAYMENT_ID, "refund-success-key"))

        assertEquals(RefundPaymentStatus.REFUNDED, result.status)
    }

    @Test
    fun `returns refund failed deterministically`() {
        val result = gateway.refund(refundRequest(MOCK_REFUND_FAILED_PAYMENT_ID, "refund-failed-key"))

        assertEquals(RefundPaymentStatus.REFUND_FAILED, result.status)
    }

    @Test
    fun `replays the original refund result for the same idempotency key and request`() {
        val request = refundRequest(MOCK_REFUNDED_PAYMENT_ID, "same-refund-key")

        val first = gateway.refund(request)
        val replay = gateway.refund(request)

        assertSame(first, replay)
        assertEquals(RefundPaymentStatus.REFUNDED, replay.status)
    }

    @Test
    fun `fails a refund when an idempotency key is reused with different input`() {
        val original = refundRequest(MOCK_REFUNDED_PAYMENT_ID, "conflicting-refund-key")
        val conflicting = original.copy(amountJpy = original.amountJpy + 1)

        assertEquals(RefundPaymentStatus.REFUNDED, gateway.refund(original).status)
        assertEquals(RefundPaymentStatus.REFUND_FAILED, gateway.refund(conflicting).status)
        assertEquals(RefundPaymentStatus.REFUNDED, gateway.refund(original).status)
    }

    @Test
    fun `concurrent identical charges share one stored result`() {
        val request = chargeRequest(MOCK_SUCCESS_PAYMENT_METHOD, "concurrent-same-key")
        val workers = 8
        val ready = CountDownLatch(workers)
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(workers)

        try {
            val futures = List(workers) {
                executor.submit<ChargePaymentResult> {
                    ready.countDown()
                    start.await()
                    gateway.charge(request)
                }
            }
            assertTrue(ready.await(10, TimeUnit.SECONDS))
            start.countDown()
            val results = futures.map { it.get(10, TimeUnit.SECONDS) }

            assertTrue(results.all { it === results.first() })
            assertTrue(results.all { it.status == ChargePaymentStatus.SUCCESS })
            assertEquals("mock-payment:concurrent-same-key", results.first().externalPaymentId)
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun `concurrent conflicting charges preserve the first stored request`() {
        val successRequest = chargeRequest(MOCK_SUCCESS_PAYMENT_METHOD, "concurrent-conflict-key")
        val declinedRequest = chargeRequest(MOCK_DECLINED_PAYMENT_METHOD, "concurrent-conflict-key")
        val ready = CountDownLatch(2)
        val start = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)

        try {
            val requests = listOf(successRequest, declinedRequest)
            val futures = requests.map { request ->
                executor.submit<ChargePaymentResult> {
                    ready.countDown()
                    start.await()
                    gateway.charge(request)
                }
            }
            assertTrue(ready.await(10, TimeUnit.SECONDS))
            start.countDown()
            val results = futures.map { it.get(10, TimeUnit.SECONDS) }

            assertEquals(1, results.count { it.status == ChargePaymentStatus.DUPLICATE })
            val winningIndex = results.indexOfFirst { it.status != ChargePaymentStatus.DUPLICATE }
            val losingIndex = 1 - winningIndex
            assertTrue(winningIndex >= 0)
            assertEquals(results[winningIndex], gateway.charge(requests[winningIndex]))
            assertEquals(ChargePaymentStatus.DUPLICATE, gateway.charge(requests[losingIndex]).status)
        } finally {
            executor.shutdownNow()
        }
    }

    @ParameterizedTest
    @ValueSource(longs = [0L, -1L])
    fun `rejects non-positive charge amounts`(amountJpy: Long) {
        assertThrows<IllegalArgumentException> {
            chargeRequest(MOCK_SUCCESS_PAYMENT_METHOD, "invalid-charge-amount").copy(amountJpy = amountJpy)
        }
    }

    @ParameterizedTest
    @ValueSource(longs = [0L, -1L])
    fun `rejects non-positive refund amounts`(amountJpy: Long) {
        assertThrows<IllegalArgumentException> {
            refundRequest(MOCK_REFUNDED_PAYMENT_ID, "invalid-refund-amount").copy(amountJpy = amountJpy)
        }
    }

    @ParameterizedTest
    @ValueSource(strings = ["", " ", "\t"])
    fun `rejects blank payment method identifiers`(paymentMethodId: String) {
        assertThrows<IllegalArgumentException> {
            chargeRequest(paymentMethodId, "blank-payment-method")
        }
    }

    @ParameterizedTest
    @ValueSource(strings = ["", " ", "\t"])
    fun `rejects blank charge idempotency keys`(idempotencyKey: String) {
        assertThrows<IllegalArgumentException> {
            chargeRequest(MOCK_SUCCESS_PAYMENT_METHOD, idempotencyKey)
        }
    }

    @ParameterizedTest
    @ValueSource(strings = ["", " ", "\t"])
    fun `rejects blank external payment identifiers`(externalPaymentId: String) {
        assertThrows<IllegalArgumentException> {
            refundRequest(externalPaymentId, "blank-external-payment")
        }
    }

    @ParameterizedTest
    @ValueSource(strings = ["", " ", "\t"])
    fun `rejects blank refund idempotency keys`(idempotencyKey: String) {
        assertThrows<IllegalArgumentException> {
            refundRequest(MOCK_REFUNDED_PAYMENT_ID, idempotencyKey)
        }
    }

    private fun chargeRequest(paymentMethodId: String, idempotencyKey: String) = ChargePaymentRequest(
        amountJpy = 10_000L,
        paymentMethodId = paymentMethodId,
        idempotencyKey = idempotencyKey
    )

    private fun refundRequest(externalPaymentId: String, idempotencyKey: String) = RefundPaymentRequest(
        externalPaymentId = externalPaymentId,
        amountJpy = 10_000L,
        idempotencyKey = idempotencyKey
    )

    companion object {
        @JvmStatic
        fun chargeScenarios(): Stream<Arguments> = Stream.of(
            Arguments.of(MOCK_SUCCESS_PAYMENT_METHOD, ChargePaymentStatus.SUCCESS),
            Arguments.of(MOCK_DECLINED_PAYMENT_METHOD, ChargePaymentStatus.DECLINED),
            Arguments.of(MOCK_FAILED_PAYMENT_METHOD, ChargePaymentStatus.FAILED),
            Arguments.of(MOCK_TIMEOUT_PAYMENT_METHOD, ChargePaymentStatus.TIMEOUT),
            Arguments.of(MOCK_DUPLICATE_PAYMENT_METHOD, ChargePaymentStatus.DUPLICATE)
        )
    }
}
