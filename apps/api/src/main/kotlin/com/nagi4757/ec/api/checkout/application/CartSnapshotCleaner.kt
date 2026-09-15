package com.nagi4757.ec.api.checkout.application

import com.nagi4757.ec.api.cart.domain.repository.CartRepository
import com.nagi4757.ec.api.order.domain.model.Order
import org.slf4j.LoggerFactory
import org.springframework.stereotype.Service

/**
 * T4. Removes exactly what the order reserved from the cart.
 *
 * Runs outside every database transaction, and after the order has been confirmed.
 * The cart lives in Redis and cannot take part in a MariaDB transaction, so a
 * failure here must not undo a payment that already succeeded: a stale cart line is
 * a cosmetic problem the customer can fix, whereas rolling back a paid order is not.
 *
 * The caller invokes this only when it was the call that confirmed the order, since
 * subtraction is not idempotent.
 */
@Service
class CartSnapshotCleaner(
    private val cartRepository: CartRepository
) {
    private val log = LoggerFactory.getLogger(javaClass)

    fun removeReservedLines(order: Order) {
        order.items.forEach { item ->
            try {
                cartRepository.removeSnapshotQuantity(
                    userId = order.userId,
                    productId = item.productId,
                    quantity = item.quantity
                )
            } catch (cause: RuntimeException) {
                // Deliberately swallowed per line: the order is paid and confirmed, and
                // no cart failure may change that. Logged so it is visible rather than
                // silent.
                log.warn(
                    "Cart cleanup failed for order {} product {}; the cart may show a stale line",
                    order.id,
                    item.productId,
                    cause
                )
            }
        }
    }
}
