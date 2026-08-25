package com.nagi4757.ec.api.order.domain.model

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class OrderStatusTest {
    @Test
    fun `allows only defined lifecycle transitions`() {
        val allowedTransitions = setOf(
            OrderStatus.PENDING to OrderStatus.PREPARING,
            OrderStatus.PENDING to OrderStatus.CANCELLED,
            OrderStatus.PREPARING to OrderStatus.SHIPPED,
            OrderStatus.PREPARING to OrderStatus.CANCELLED,
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
    fun `allows user cancellation only while pending`() {
        assertTrue(OrderStatus.PENDING.isUserCancellable())
        OrderStatus.entries
            .filterNot { it == OrderStatus.PENDING }
            .forEach { assertFalse(it.isUserCancellable()) }
    }
}
