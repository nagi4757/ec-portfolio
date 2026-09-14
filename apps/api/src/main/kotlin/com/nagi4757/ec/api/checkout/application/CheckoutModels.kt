package com.nagi4757.ec.api.checkout.application

import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.ShippingAddress

/** Currency is fixed for this store and is part of the request identity. */
const val CHECKOUT_CURRENCY = "JPY"

/**
 * A checkout request. There is deliberately no amount field: the total is derived
 * from the cart and the product snapshot on the server, so a client cannot choose
 * what it pays.
 */
data class CheckoutCommand(
    val userId: Long,
    val shippingAddress: ShippingAddress,
    val paymentMethodId: String,
    val idempotencyKey: String
) {
    init {
        require(paymentMethodId.isNotBlank()) { "Payment method id must not be blank" }
        require(idempotencyKey.isNotBlank()) { "Idempotency key must not be blank" }
    }
}

/** Outcome of a reservation: the order that now holds stock, and its attempt. */
data class ReservedCheckout(
    val order: Order,
    val paymentAttemptId: Long,
    val requestFingerprint: String,
    val amountJpy: Long
)

/** What the caller is told once the charge has been resolved. */
data class CheckoutResult(
    val order: Order,
    val outcome: CheckoutOutcome
)

enum class CheckoutOutcome {
    /** Charged and confirmed. */
    PAID,

    /** The gateway refused. Stock was returned and the order cancelled. */
    DECLINED,

    /** The charge could not be processed. Stock was returned and the order cancelled. */
    FAILED,

    /**
     * The gateway did not report an outcome. The order stays reserved and holds its
     * stock so it can be reconciled; it is never silently cancelled, because the
     * charge may well have succeeded.
     */
    PENDING_CONFIRMATION
}
