package com.nagi4757.ec.api.refund.application

import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.domain.repository.OrderRepository
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import com.nagi4757.ec.api.refund.domain.model.RefundAttempt
import com.nagi4757.ec.api.refund.domain.model.RefundAttemptStatus
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Propagation
import org.springframework.transaction.annotation.Transactional

/**
 * R3. Moves the order out of REFUND_PENDING once the refund outcome is known.
 *
 * Every action is gated on a conditional transition away from REFUND_PENDING, which
 * makes this idempotent in the two ways that matter. A retry arriving after a
 * crashed R3 still finalises the order, and a retry arriving after a completed one
 * changes nothing. Stock is restored only by the call that actually cancelled the
 * order, so repeating this cannot inflate stock.
 */
@Service
class RefundFinalizeService(
    private val orderRepository: OrderRepository,
    private val productRepository: ProductRepository
) {
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    fun finalize(attempt: RefundAttempt): RefundFinalizeOutcome {
        val order = orderRepository.findById(attempt.orderId)
            ?: error("Order ${attempt.orderId} disappeared during refund")

        return when (attempt.status) {
            RefundAttemptStatus.REFUNDED -> cancel(order)
            RefundAttemptStatus.FAILED -> restore(order, attempt.orderStatusBefore)
            // The money may or may not have moved. Holding the order in
            // REFUND_PENDING is the only safe option: cancelling it would give the
            // goods back without knowing the customer was paid, and releasing it
            // would hide an unresolved refund.
            RefundAttemptStatus.UNKNOWN, RefundAttemptStatus.PENDING ->
                RefundFinalizeOutcome(order = order, changed = false)
        }
    }

    private fun cancel(order: Order): RefundFinalizeOutcome {
        val orderId = requireNotNull(order.id)
        val changed = orderRepository.transitionStatus(
            id = orderId,
            expectedStatus = OrderStatus.REFUND_PENDING,
            targetStatus = OrderStatus.CANCELLED
        )
        if (changed) {
            restoreStock(order)
        }

        return RefundFinalizeOutcome(order = reload(orderId), changed = changed)
    }

    /** A refused refund puts the order back exactly where it came from. */
    private fun restore(order: Order, statusBefore: OrderStatus): RefundFinalizeOutcome {
        val orderId = requireNotNull(order.id)
        val changed = orderRepository.transitionStatus(
            id = orderId,
            expectedStatus = OrderStatus.REFUND_PENDING,
            targetStatus = statusBefore
        )

        return RefundFinalizeOutcome(order = reload(orderId), changed = changed)
    }

    private fun restoreStock(order: Order) {
        order.items.forEach { item ->
            check(productRepository.increaseStock(item.productId, item.quantity)) {
                "Failed to restore stock for product ${item.productId}"
            }
        }
    }

    private fun reload(orderId: Long): Order =
        orderRepository.findById(orderId) ?: error("Order $orderId disappeared")
}

data class RefundFinalizeOutcome(
    val order: Order,
    /** True when this call performed the transition, false when it was already done. */
    val changed: Boolean
)
