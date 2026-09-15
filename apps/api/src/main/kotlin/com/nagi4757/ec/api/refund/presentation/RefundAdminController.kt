package com.nagi4757.ec.api.refund.presentation

import com.nagi4757.ec.api.common.config.ApiErrorCodes
import com.nagi4757.ec.api.common.config.OpenApiConfig
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.RefundFailedException
import com.nagi4757.ec.api.order.presentation.shared.toResponse
import com.nagi4757.ec.api.refund.application.RefundCommand
import com.nagi4757.ec.api.refund.application.RefundCoordinator
import com.nagi4757.ec.api.refund.application.RefundOutcome
import com.nagi4757.ec.api.refund.application.RefundReconcileCommand
import com.nagi4757.ec.api.refund.application.RefundResult
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.responses.ApiResponse
import io.swagger.v3.oas.annotations.responses.ApiResponses
import io.swagger.v3.oas.annotations.security.SecurityRequirement
import io.swagger.v3.oas.annotations.tags.Tag
import jakarta.validation.constraints.NotBlank
import jakarta.validation.constraints.Size
import org.springframework.http.ResponseEntity
import org.springframework.validation.annotation.Validated
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestHeader
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

/**
 * The operator path to the same orchestration.
 *
 * It is a separate endpoint rather than a status transition: reopening CANCELLED in
 * the admin transition table would recreate a way to cancel a paid order without
 * returning the money. Both paths contend for the same order row lock, so a customer
 * and an operator cannot start two refunds for one order.
 */
@RestController
@RequestMapping("/api/admin/orders/{id}/refund")
@Validated
@Tag(name = "Admin - Refunds")
@SecurityRequirement(name = OpenApiConfig.BEARER_AUTH_NAME)
@ApiErrorCodes(ApiErrorCode.UNAUTHORIZED, ApiErrorCode.ACCESS_DENIED)
class RefundAdminController(
    private val refundCoordinator: RefundCoordinator
) {
    @PostMapping
    @Operation(summary = "Refund a paid order in full and cancel it")
    @ApiResponses(
        ApiResponse(responseCode = "200", description = "Refunded and cancelled"),
        ApiResponse(responseCode = "202", description = "The refund is not yet confirmed")
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
    ): ResponseEntity<RefundResponse> = respond(
        // userId is null: an operator acts on any order, so the ownership check does
        // not apply to this path.
        refundCoordinator.refund(
            RefundCommand(orderId = id, userId = null, idempotencyKey = idempotencyKey)
        )
    )

    @PostMapping("/reconcile")
    @Operation(
        summary = "Resume this order's refund without an idempotency key",
        description = "Resumes the refund already stored against the order using the key " +
            "recorded on it, including one a customer started. Admin storage is a " +
            "different origin from the storefront's, so an operator never has the " +
            "customer's key. This never starts a refund."
    )
    @ApiResponses(
        ApiResponse(responseCode = "200", description = "Refunded and cancelled"),
        ApiResponse(responseCode = "202", description = "The refund is still not confirmed")
    )
    @ApiErrorCodes(
        ApiErrorCode.ORDER_NOT_FOUND,
        ApiErrorCode.REFUND_NOT_ELIGIBLE,
        ApiErrorCode.REFUND_FAILED,
        ApiErrorCode.REFUND_IDEMPOTENCY_CONFLICT
    )
    fun reconcile(@PathVariable id: Long): ResponseEntity<RefundResponse> = respond(
        refundCoordinator.reconcile(RefundReconcileCommand(orderId = id, userId = null))
    )

    private fun respond(result: RefundResult): ResponseEntity<RefundResponse> {
        val body = RefundResponse(outcome = result.outcome.name, order = result.order.toResponse())

        return when (result.outcome) {
            RefundOutcome.REFUNDED -> ResponseEntity.ok(body)
            RefundOutcome.PENDING_CONFIRMATION -> ResponseEntity.accepted().body(body)
            RefundOutcome.FAILED -> throw RefundFailedException()
        }
    }
}
