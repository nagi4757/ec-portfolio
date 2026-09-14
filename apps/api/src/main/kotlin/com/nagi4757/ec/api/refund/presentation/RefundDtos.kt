package com.nagi4757.ec.api.refund.presentation

import com.nagi4757.ec.api.order.presentation.shared.OrderResponse
import com.nagi4757.ec.api.refund.application.RefundOutcome
import io.swagger.v3.oas.annotations.media.Schema

/**
 * A refund carries no request body.
 *
 * The amount and the charge being reversed are read from the order's settled
 * payment on the server. A client that could name either could choose how much it
 * is refunded, or which charge is reversed.
 */
@Schema(name = "RefundResponse")
data class RefundResponse(
    @field:Schema(implementation = RefundOutcome::class)
    val outcome: String,
    val order: OrderResponse
)
