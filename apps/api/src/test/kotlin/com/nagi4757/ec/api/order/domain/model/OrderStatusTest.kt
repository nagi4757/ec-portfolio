package com.nagi4757.ec.api.order.domain.model

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class OrderStatusTest {
    @Test
    fun `allows only defined lifecycle transitions`() {
        // Cancellation is absent from every paid state: money has been captured and
        // refund orchestration does not exist yet, so those transitions fail closed.
        val allowedTransitions = setOf(
            OrderStatus.PENDING to OrderStatus.PREPARING,
            OrderStatus.PREPARING to OrderStatus.SHIPPED,
            OrderStatus.SHIPPED to OrderStatus.DELIVERED
        )

        OrderStatus.entries.forEach { current ->
            OrderStatus.entries.forEach { target ->
                if (current to target in allowedTransitions) {
                    assertTrue(current.canTransitionTo(target), "$current should transition to $target")
                } else {
                    assertFalse(current.canTransitionTo(target), "$current should not transition to $target")
                }
            }
        }
    }

    @Test
    fun `rejects transitions from terminal statuses`() {
        OrderStatus.entries.forEach { target ->
            assertFalse(OrderStatus.DELIVERED.canTransitionTo(target))
            assertFalse(OrderStatus.CANCELLED.canTransitionTo(target))
        }
    }

    @Test
    fun `rejects transitions to the same status`() {
        OrderStatus.entries.forEach { status ->
            assertFalse(status.canTransitionTo(status))
        }
    }

    @Test
    fun `rejects reverse lifecycle transitions`() {
        val reverseTransitions = listOf(
            OrderStatus.PREPARING to OrderStatus.PENDING,
            OrderStatus.SHIPPED to OrderStatus.PREPARING,
            OrderStatus.DELIVERED to OrderStatus.SHIPPED
        )

        reverseTransitions.forEach { (current, target) ->
            assertFalse(current.canTransitionTo(target))
        }
    }

    @Test
    fun `refuses direct customer cancellation in every state`() {
        // A paid order needs a refund; a reserved one has an unresolved payment.
        OrderStatus.entries.forEach { assertFalse(it.isUserCancellable(), "$it must not be user cancellable") }
    }

    @Test
    fun `allows compensation only from the reserved state`() {
        assertTrue(OrderStatus.PAYMENT_PENDING.canCompensateTo(OrderStatus.CANCELLED))

        OrderStatus.entries
            .filterNot { it == OrderStatus.PAYMENT_PENDING }
            .forEach { assertFalse(it.canCompensateTo(OrderStatus.CANCELLED), "$it must not be compensated") }

        // Compensation exists to cancel an unpaid reservation, nothing else.
        OrderStatus.entries
            .filterNot { it == OrderStatus.CANCELLED }
            .forEach { assertFalse(OrderStatus.PAYMENT_PENDING.canCompensateTo(it)) }
    }

    @Test
    fun `treats every post payment state as paid`() {
        listOf(OrderStatus.PENDING, OrderStatus.PREPARING, OrderStatus.SHIPPED, OrderStatus.DELIVERED)
            .forEach { assertTrue(it.isPaid(), "$it must count as paid") }

        listOf(OrderStatus.PAYMENT_PENDING, OrderStatus.CANCELLED)
            .forEach { assertFalse(it.isPaid(), "$it must not count as paid") }
    }

    @Test
    fun `refuses every operator transition out of the reserved state`() {
        // Preparing or shipping an order whose payment is unresolved would ship goods
        // that may never have been paid for.
        OrderStatus.entries.forEach {
            assertFalse(OrderStatus.PAYMENT_PENDING.canTransitionTo(it), "PAYMENT_PENDING must not reach $it")
        }
    }
}
