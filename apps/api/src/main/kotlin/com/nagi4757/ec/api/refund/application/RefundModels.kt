package com.nagi4757.ec.api.refund.application

import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.refund.domain.model.RefundAttempt

/**
 * A request to refund an order in full and cancel it.
 *
 * There is deliberately no amount and no payment reference: both are read from the
 * order's settled charge on the server. A client that could name either could
 * choose how much it is refunded, or which charge is reversed.
 */
data class RefundCommand(
    val orderId: Long,
    /** The authenticated caller, or null when an operator is acting. */
    val userId: Long?,
    val idempotencyKey: String
) {
    init {
        require(idempotencyKey.isNotBlank()) { "Idempotency key must not be blank" }
    }
}

/**
 * A request to resume the refund an order already has.
 *
 * Deliberately carries no idempotency key. Reconciliation never starts a refund, so
 * there is nothing for a client-supplied key to identify; the key that goes to the
 * provider is the one already stored on the attempt. Accepting a key here would let
 * a caller who lost the original one attach a new key to someone else's in-flight
 * refund, which is the opposite of what an idempotency key is for.
 */
data class RefundReconcileCommand(
    val orderId: Long,
    /** The authenticated caller, or null when an operator is acting. */
    val userId: Long?
)

/** What R1 decided: a fresh refund, or an existing one this request continues. */
sealed interface RefundStartOutcome {
    data class Started(val attempt: RefundAttempt, val order: Order) : RefundStartOutcome
    data class Existing(val attempt: RefundAttempt) : RefundStartOutcome
}

data class RefundResult(
    val order: Order,
    val outcome: RefundOutcome
)

enum class RefundOutcome {
    /** Money returned and the order cancelled. */
    REFUNDED,

    /** The provider refused. The order is put back where it was. */
    FAILED,

    /**
     * The provider did not report an outcome. The order stays in REFUND_PENDING so
     * it can be reconciled; it is never cancelled on a guess, because the money may
     * not have moved.
     */
    PENDING_CONFIRMATION
}
