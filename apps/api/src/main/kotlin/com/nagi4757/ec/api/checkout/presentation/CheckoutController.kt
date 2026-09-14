package com.nagi4757.ec.api.checkout.presentation

import com.nagi4757.ec.api.checkout.application.CheckoutCommand
import com.nagi4757.ec.api.checkout.application.CheckoutCoordinator
import com.nagi4757.ec.api.checkout.application.CheckoutOutcome
import com.nagi4757.ec.api.common.config.ApiErrorCodes
import com.nagi4757.ec.api.common.config.OpenApiConfig
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.security.JwtUserClaims
import com.nagi4757.ec.api.order.presentation.shared.toDomain
import com.nagi4757.ec.api.order.presentation.shared.toResponse
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.responses.ApiResponse
import io.swagger.v3.oas.annotations.responses.ApiResponses
import io.swagger.v3.oas.annotations.security.SecurityRequirement
import io.swagger.v3.oas.annotations.tags.Tag
import jakarta.validation.Valid
import jakarta.validation.constraints.NotBlank
import jakarta.validation.constraints.Size
import org.springframework.http.HttpStatus
import org.springframework.http.ResponseEntity
import org.springframework.security.core.context.SecurityContextHolder
import org.springframework.validation.annotation.Validated
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestHeader
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController
import org.springframework.web.server.ResponseStatusException

/**
 * The only way to create an order. Orders cannot be created without going through a
 * payment, so there is no unauthenticated or payment-free path to one.
 */
@RestController
@RequestMapping("/api/user/checkout")
@Validated
@Tag(name = "User - Checkout")
@SecurityRequirement(name = OpenApiConfig.BEARER_AUTH_NAME)
@ApiErrorCodes(ApiErrorCode.UNAUTHORIZED)
class CheckoutController(
    private val checkoutCoordinator: CheckoutCoordinator
) {
    @PostMapping
    @Operation(
        summary = "Pay for the current cart and create the order",
        description = "The total is computed on the server from the cart. Repeating a " +
            "request with the same Idempotency-Key replays the original outcome."
    )
    @ApiResponses(
        ApiResponse(responseCode = "201", description = "Charged and confirmed"),
        ApiResponse(
            responseCode = "202",
            description = "The gateway did not confirm the charge. The order is reserved " +
                "and awaiting reconciliation; it has not been cancelled."
        ),
        ApiResponse(responseCode = "402", description = "DECLINED or FAILED")
    )
    @ApiErrorCodes(
        ApiErrorCode.EMPTY_CART,
        ApiErrorCode.VALIDATION_FAILED,
        ApiErrorCode.MALFORMED_REQUEST,
        ApiErrorCode.PRODUCT_NOT_FOUND,
        ApiErrorCode.PRODUCT_NOT_AVAILABLE,
        ApiErrorCode.INSUFFICIENT_STOCK,
        ApiErrorCode.PAYMENT_DECLINED,
        ApiErrorCode.PAYMENT_FAILED,
        ApiErrorCode.PAYMENT_IDEMPOTENCY_CONFLICT
    )
    fun checkout(
        @RequestHeader("Idempotency-Key")
        @NotBlank
        @Size(max = 255)
        idempotencyKey: String,
        @Valid @RequestBody request: CheckoutRequest
    ): ResponseEntity<CheckoutResponse> {
        val result = checkoutCoordinator.checkout(
            CheckoutCommand(
                userId = currentUserId(),
                shippingAddress = request.shippingAddress.toDomain(),
                paymentMethodId = request.paymentMethodId,
                idempotencyKey = idempotencyKey
            )
        )

        val body = CheckoutResponse(
            outcome = result.outcome.name,
            order = result.order.toResponse()
        )

        // An unresolved charge is reported as 202 with the reserved order attached,
        // not as an error: the order exists, holds its stock, and is awaiting
        // reconciliation. A declined or failed charge is a client-visible payment
        // problem and is reported as 402 through the error handler.
        return when (result.outcome) {
            CheckoutOutcome.PAID -> ResponseEntity.status(HttpStatus.CREATED).body(body)
            CheckoutOutcome.PENDING_CONFIRMATION -> ResponseEntity.accepted().body(body)
            CheckoutOutcome.DECLINED -> ResponseEntity.status(HttpStatus.PAYMENT_REQUIRED).body(body)
            CheckoutOutcome.FAILED -> ResponseEntity.status(HttpStatus.PAYMENT_REQUIRED).body(body)
        }
    }

    private fun currentUserId(): Long {
        val principal = SecurityContextHolder.getContext().authentication?.principal as? JwtUserClaims
            ?: throw ResponseStatusException(HttpStatus.UNAUTHORIZED, "Unauthorized")
        return principal.userId
    }
}
