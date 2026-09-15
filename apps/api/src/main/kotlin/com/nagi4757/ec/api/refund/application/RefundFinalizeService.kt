package com.nagi4757.ec.api.refund.application

import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.domain.repository.OrderRepository
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import com.nagi4757.ec.api.refund.domain.model.RefundAttempt
import com.nagi4757.ec.api.refund.domain.model.RefundAttemptStatus
import com.nagi4757.ec.api.refund.domain.repository.RefundAttemptRepository
import org.slf4j.LoggerFactory
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Propagation
import org.springframework.transaction.annotation.Transactional

/**
 * R3. Moves the order out of REFUND_PENDING once the refund outcome is known.
 *
 * ## Why this takes the order lock and re-reads the attempt
 *
 * An order can accumulate several refund attempts over its life: a refused refund
 * puts the order back where it was, and the customer may then start a new one. Every
 * attempt is replayable, so an older attempt can arrive here long after a newer one
 * has claimed the order.
 *
 * Gating only on "is the order REFUND_PENDING" cannot tell those apart. A settled
 * FAILED attempt replayed while a newer refund holds the order would find
 * REFUND_PENDING, read it as its own, and release the order the newer refund is
 * relying on. The newer refund would then succeed at the provider and find nothing
 * left to cancel: the money would be gone, stock never restored, and the order
 * shippable again.
 *
 * So this takes the order row lock and asks the database which attempt currently
 * speaks for the order. Attempts are only ever created under that same lock (R1), so
 * holding it means no newer attempt can appear between the read and the write below.
 * Only the newest attempt may act; anything older is a stale replay and returns
 * without touching the order.
 *
 * The persisted status is authoritative too. The caller's [RefundAttempt] is a
 * snapshot that may predate a concurrent R2, and acting on a stale status could
 * cancel an order whose refund has since been refused.
 *
 * Within the current attempt this stays idempotent as before: every action is gated
 * on a conditional transition away from REFUND_PENDING, so a retry after a crashed
 * R3 still finalises the order and a retry after a completed one changes nothing.
 * Stock is restored only by the call that actually performed the cancellation.
 */
@Service
class RefundFinalizeService(
    private val orderRepository: OrderRepository,
    private val productRepository: ProductRepository,
    private val refundAttemptRepository: RefundAttemptRepository
) {
    private val log = LoggerFactory.getLogger(javaClass)

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    fun finalize(attempt: RefundAttempt): RefundFinalizeOutcome {
        val attemptId = requireNotNull(attempt.id) { "A refund attempt must be persisted before R3" }

        // Lock first. Everything read after this point stays stable until commit.
        val order = orderRepository.lockForUpdate(attempt.orderId)
            ?: error("Order ${attempt.orderId} disappeared during refund")

        val latest = refundAttemptRepository.findLatestByOrderId(attempt.orderId)
        if (latest == null) {
            // The attempt that brought us here is not among the order's attempts.
            // That is a data problem rather than a request problem, and guessing a
            // recovery could cancel an order no refund ever paid for.
            log.error(
                "Refund attempt {} finalising order {} has no persisted attempt for that order; refusing to act",
                attemptId,
                attempt.orderId
            )
            return RefundFinalizeOutcome(order = order, changed = false, stale = true)
        }

        if (latest.id != attemptId) {
            // A newer refund owns this order now. Releasing REFUND_PENDING here would
            // strip that refund of the state it depends on.
            log.info(
                "Refund attempt {} is stale for order {}; attempt {} is current. Leaving the order untouched.",
                attemptId,
                attempt.orderId,
                latest.id
            )
            return RefundFinalizeOutcome(order = order, changed = false, stale = true)
        }

        return when (latest.status) {
            RefundAttemptStatus.REFUNDED -> cancel(order)
            RefundAttemptStatus.FAILED -> restore(order, latest.orderStatusBefore)
            // The money may or may not have moved. Holding the order in
            // REFUND_PENDING is the only safe option: cancelling it would give the
            // goods back without knowing the customer was paid, and releasing it
            // would hide an unresolved refund.
            RefundAttemptStatus.UNKNOWN, RefundAttemptStatus.PENDING ->
                RefundFinalizeOutcome(order = order, changed = false, stale = false)
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

        return RefundFinalizeOutcome(order = reload(orderId), changed = changed, stale = false)
    }

    /** A refused refund puts the order back exactly where it came from. */
    private fun restore(order: Order, statusBefore: OrderStatus): RefundFinalizeOutcome {
        val orderId = requireNotNull(order.id)
        val changed = orderRepository.transitionStatus(
            id = orderId,
            expectedStatus = OrderStatus.REFUND_PENDING,
            targetStatus = statusBefore
        )

        return RefundFinalizeOutcome(order = reload(orderId), changed = changed, stale = false)
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
    val changed: Boolean,
    /**
     * True when this attempt no longer speaks for the order, so nothing was touched.
     * Distinct from `changed = false`, which also covers a legitimate replay of the
     * attempt that is current.
     */
    val stale: Boolean
)
