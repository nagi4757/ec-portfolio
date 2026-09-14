package com.nagi4757.ec.api.refund.presentation

import com.nagi4757.ec.api.common.config.ApiErrorCodes
import com.nagi4757.ec.api.common.config.OpenApiConfig
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.RefundFailedException
import com.nagi4757.ec.api.common.security.JwtUserClaims
import com.nagi4757.ec.api.order.presentation.shared.toResponse
import com.nagi4757.ec.api.refund.application.RefundCommand
import com.nagi4757.ec.api.refund.application.RefundCoordinator
import com.nagi4757.ec.api.refund.application.RefundOutcome
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.responses.ApiResponse
import io.swagger.v3.oas.annotations.responses.ApiResponses
import io.swagger.v3.oas.annotations.security.SecurityRequirement
import io.swagger.v3.oas.annotations.tags.Tag
import jakarta.validation.constraints.NotBlank
import jakarta.validation.constraints.Size
import org.springframework.http.HttpStatus
import org.springframework.http.ResponseEntity
import org.springframework.security.core.context.SecurityContextHolder
import org.springframework.validation.annotation.Validated
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestHeader
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController
import org.springframework.web.server.ResponseStatusException

/**
 * Refunding a paid order and cancelling it. This is the only way a paid order can be
 * cancelled: the money goes back first, and the order is cancelled only once the
 * provider has confirmed it.
 */
@RestController
@RequestMapping("/api/user/orders/{id}/refund")
@Validated
@Tag(name = "User - Refunds")
@SecurityRequirement(name = OpenApiConfig.BEARER_AUTH_NAME)
@ApiErrorCodes(ApiErrorCode.UNAUTHORIZED)
class RefundUserController(
    private val refundCoordinator: RefundCoordinator
) {
    @PostMapping
    @Operation(
        summary = "Refund a paid order in full and cancel it",
        description = "The amount is taken from the order's settled charge. Repeating " +
            "a request with the same Idempotency-Key replays the original outcome."
    )
    @ApiResponses(
        ApiResponse(responseCode = "200", description = "Refunded and cancelled"),
        ApiResponse(
            responseCode = "202",
            description = "The provider did not confirm the refund. The order is held " +
                "for reconciliation and has not been cancelled."
        )
    )
    @ApiErrorCodes(
        ApiErrorCode.ORDER_NOT_FOUND,
        ApiErrorCode.REFUND_NOT_ELIGIBLE,
        ApiErrorCode.REFUND_FAILED,
        ApiErrorCode.REFUND_ATTEMPT_IN_PROGRESS,
        ApiErrorCode.REFUND_IDEMPOTENCY_CONFLICT
    )
    fun refund(
        @PathVariable id: Long,
        @RequestHeader("Idempotency-Key")
        @NotBlank
        @Size(max = 255)
        idempotencyKey: String
    ): ResponseEntity<RefundResponse> {
        val result = refundCoordinator.refund(
            RefundCommand(orderId = id, userId = currentUserId(), idempotencyKey = idempotencyKey)
        )

        val body = RefundResponse(outcome = result.outcome.name, order = result.order.toResponse())

        // An unresolved refund is reported as 202 with the order attached, not as an
        // error: the order exists and is awaiting reconciliation. A refusal is a
        // client-visible conflict and goes through the error handler.
        return when (result.outcome) {
            RefundOutcome.REFUNDED -> ResponseEntity.ok(body)
            RefundOutcome.PENDING_CONFIRMATION -> ResponseEntity.accepted().body(body)
            RefundOutcome.FAILED -> throw RefundFailedException()
        }
    }

    private fun currentUserId(): Long {
        val principal = SecurityContextHolder.getContext().authentication?.principal as? JwtUserClaims
            ?: throw ResponseStatusException(HttpStatus.UNAUTHORIZED, "Unauthorized")
        return principal.userId
    }
}
