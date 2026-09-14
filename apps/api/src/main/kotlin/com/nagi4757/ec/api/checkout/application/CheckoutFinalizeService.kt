package com.nagi4757.ec.api.checkout.application

import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.domain.repository.OrderRepository
import com.nagi4757.ec.api.payment.domain.model.PaymentAttemptStatus
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Propagation
import org.springframework.transaction.annotation.Transactional

/**
 * T3. Moves the order out of PAYMENT_PENDING once the payment outcome is known.
 *
 * Every action is gated on a conditional transition away from PAYMENT_PENDING, which
 * makes this operation idempotent in a way that matters twice over. A retry that
 * arrives after a crashed T3 still finalises the order, and a retry that arrives
 * after a completed one changes nothing. Stock is only returned by the call that
 * actually cancelled the order, so a repeated compensation cannot inflate stock.
 *
 * [FinalizeOutcome.changed] tells the caller whether this call was the one that
 * moved the order. Cart cleanup is not idempotent, so it hangs off that flag.
 */
@Service
class CheckoutFinalizeService(
    private val orderRepository: OrderRepository,
    private val productRepository: ProductRepository
) {
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    fun finalize(orderId: Long, attemptStatus: PaymentAttemptStatus): FinalizeOutcome {
        val order = orderRepository.findById(orderId)
            ?: error("Reserved order $orderId disappeared")

        return when (attemptStatus) {
            PaymentAttemptStatus.SUCCESS -> confirm(order)
            PaymentAttemptStatus.DECLINED, PaymentAttemptStatus.FAILED -> compensate(order)
            // The charge may or may not have happened. Holding the reservation is the
            // only safe option: releasing the stock and cancelling would risk taking
            // the money and shipping nothing.
            PaymentAttemptStatus.TIMEOUT, PaymentAttemptStatus.PENDING ->
                FinalizeOutcome(order = order, changed = false)
        }
    }

    private fun confirm(order: Order): FinalizeOutcome {
        val orderId = requireNotNull(order.id)
        val changed = orderRepository.transitionStatus(
            id = orderId,
            expectedStatus = OrderStatus.PAYMENT_PENDING,
            targetStatus = OrderStatus.PENDING
        )

        return FinalizeOutcome(order = reload(orderId), changed = changed)
    }

    private fun compensate(order: Order): FinalizeOutcome {
        val orderId = requireNotNull(order.id)

        // The conditional transition is what enforces OrderStatus.canCompensateTo:
        // it only matches while the order is still PAYMENT_PENDING, which is the
        // one state where cancelling needs no refund.
        val changed = orderRepository.transitionStatus(
            id = orderId,
            expectedStatus = OrderStatus.PAYMENT_PENDING,
            targetStatus = OrderStatus.CANCELLED
        )
        if (changed) {
            restoreStock(order)
        }

        return FinalizeOutcome(order = reload(orderId), changed = changed)
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

data class FinalizeOutcome(
    val order: Order,
    /** True when this call performed the transition, false when it was already done. */
    val changed: Boolean
)
