package com.nagi4757.ec.api.order.presentation.user

import com.nagi4757.ec.api.common.config.ApiErrorCodes
import com.nagi4757.ec.api.common.config.OpenApiConfig
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.security.JwtUserClaims
import com.nagi4757.ec.api.order.application.OrderService
import com.nagi4757.ec.api.order.presentation.shared.OrderResponse
import com.nagi4757.ec.api.order.presentation.shared.OrderSummaryResponse
import com.nagi4757.ec.api.order.presentation.shared.toResponse
import com.nagi4757.ec.api.order.presentation.shared.toSummary
import io.swagger.v3.oas.annotations.Operation
import io.swagger.v3.oas.annotations.security.SecurityRequirement
import io.swagger.v3.oas.annotations.tags.Tag
import org.springframework.http.HttpStatus
import org.springframework.security.core.context.SecurityContextHolder
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.ResponseStatus
import org.springframework.web.bind.annotation.RestController
import org.springframework.web.server.ResponseStatusException

@RestController
@RequestMapping("/api/user/orders")
@Tag(name = "User - Orders")
@SecurityRequirement(name = OpenApiConfig.BEARER_AUTH_NAME)
@ApiErrorCodes(ApiErrorCode.UNAUTHORIZED)
class OrderUserController(
    private val orderService: OrderService
) {
    /* 장바구니 → 주문 생성 */
    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    @Operation(summary = "Create an order from the current cart")
    @ApiErrorCodes(
        ApiErrorCode.EMPTY_CART,
        ApiErrorCode.PRODUCT_NOT_FOUND,
        ApiErrorCode.PRODUCT_NOT_AVAILABLE,
        ApiErrorCode.INSUFFICIENT_STOCK
    )
    fun placeOrder(): OrderResponse =
        orderService.placeOrder(currentUserId()).toResponse()

    /* 내 주문 목록 */
    @GetMapping
    fun getOrders(): List<OrderSummaryResponse> =
        orderService.getOrders(currentUserId()).map { it.toSummary() }

    /* 내 주문 상세 */
    @GetMapping("/{id}")
    @Operation(operationId = "getUserOrder")
    @ApiErrorCodes(ApiErrorCode.ORDER_NOT_FOUND)
    fun getOrder(@PathVariable id: Long): OrderResponse =
        orderService.getOrder(currentUserId(), id).toResponse()

    @PostMapping("/{id}/cancel")
    @Operation(summary = "Cancel a pending order")
    @ApiErrorCodes(ApiErrorCode.ORDER_NOT_FOUND, ApiErrorCode.INVALID_ORDER_TRANSITION)
    fun cancelOrder(@PathVariable id: Long): OrderResponse =
        orderService.cancelOrder(currentUserId(), id).toResponse()

    private fun currentUserId(): Long {
        val principal = SecurityContextHolder.getContext().authentication?.principal as? JwtUserClaims
            ?: throw ResponseStatusException(HttpStatus.UNAUTHORIZED, "Unauthorized")
        return principal.userId
    }
}
