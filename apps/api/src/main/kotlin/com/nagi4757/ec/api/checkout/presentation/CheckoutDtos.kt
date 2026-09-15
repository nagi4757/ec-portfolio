package com.nagi4757.ec.api.checkout.presentation

import com.nagi4757.ec.api.checkout.application.CheckoutOutcome
import com.nagi4757.ec.api.order.presentation.shared.OrderResponse
import com.nagi4757.ec.api.order.presentation.shared.ShippingAddressRequest
import io.swagger.v3.oas.annotations.media.Schema
import jakarta.validation.Valid
import jakarta.validation.constraints.NotBlank
import jakarta.validation.constraints.Size

/**
 * A checkout request carries no amount.
 *
 * The total is computed on the server from the cart and the product snapshot. If the
 * client could state what it pays, it could pay one yen for anything.
 */
@Schema(name = "CheckoutRequest")
data class CheckoutRequest(
    @field:Valid
    val shippingAddress: ShippingAddressRequest,

    @field:NotBlank
    @field:Size(max = 255)
    @field:Schema(
        description = "Payment method token. The mock gateway accepts mock:success, " +
            "mock:declined, mock:failed and mock:timeout."
    )
    val paymentMethodId: String
)

@Schema(name = "CheckoutResponse")
data class CheckoutResponse(
    @field:Schema(implementation = CheckoutOutcome::class)
    val outcome: String,
    val order: OrderResponse
)
