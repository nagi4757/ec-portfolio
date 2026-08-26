package com.nagi4757.ec.api.order.presentation.admin

import com.nagi4757.ec.api.common.config.ApiErrorCodes
import com.nagi4757.ec.api.common.config.OpenApiConfig
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.InvalidOrderStatusException
import com.nagi4757.ec.api.order.application.OrderService
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.presentation.shared.OrderListResponse
import com.nagi4757.ec.api.order.presentation.shared.OrderRequest
import com.nagi4757.ec.api.order.presentation.shared.OrderResponse
import com.nagi4757.ec.api.order.presentation.shared.toResponse
import jakarta.validation.Valid
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.Parameter
import io.swagger.v3.oas.annotations.security.SecurityRequirement
import io.swagger.v3.oas.annotations.tags.Tag
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PatchMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RequestParam
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api/admin/orders")
@Tag(name = "Admin - Orders")
@SecurityRequirement(name = OpenApiConfig.BEARER_AUTH_NAME)
@ApiErrorCodes(ApiErrorCode.UNAUTHORIZED, ApiErrorCode.ACCESS_DENIED)
class OrderAdminController(
    private val orderService: OrderService
) {
    /* 전체 주문 목록 (페이지네이션) */
    @GetMapping
    @ApiErrorCodes(ApiErrorCode.BAD_REQUEST)
    fun listOrders(
        @Parameter(description = "One-based page number. Values below 1 are normalized to 1.")
        @RequestParam(defaultValue = "1") page: Int,
        @Parameter(description = "Page size. Values are normalized to the range 1 through 100.")
        @RequestParam(defaultValue = "20") size: Int
    ): OrderListResponse = orderService.listAllOrders(page, size).toResponse()

    /* 주문 상세 */
    @GetMapping("/{id}")
    @Operation(operationId = "getAdminOrder")
    @ApiErrorCodes(ApiErrorCode.ORDER_NOT_FOUND)
    fun getOrder(@PathVariable id: Long): OrderResponse =
        orderService.getOrderAdmin(id).toResponse()

    /* 주문 상태 변경 */
    @PatchMapping("/{id}/status")
    @Operation(summary = "Transition an order to the requested status")
    @ApiErrorCodes(
        ApiErrorCode.VALIDATION_FAILED,
        ApiErrorCode.MALFORMED_REQUEST,
        ApiErrorCode.INVALID_ORDER_STATUS,
        ApiErrorCode.ORDER_NOT_FOUND,
        ApiErrorCode.INVALID_ORDER_TRANSITION
    )
    fun updateStatus(
        @PathVariable id: Long,
        @Valid @RequestBody req: OrderRequest.UpdateStatus
    ): OrderResponse {
        val status = runCatching { OrderStatus.valueOf(req.status) }.getOrNull()
            ?: throw InvalidOrderStatusException()
        return orderService.updateStatus(id, status).toResponse()
    }
}
