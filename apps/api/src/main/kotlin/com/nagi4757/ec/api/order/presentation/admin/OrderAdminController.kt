package com.nagi4757.ec.api.order.presentation.admin

import com.nagi4757.ec.api.order.application.OrderService
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.presentation.shared.OrderListResponse
import com.nagi4757.ec.api.order.presentation.shared.OrderRequest
import com.nagi4757.ec.api.order.presentation.shared.OrderResponse
import com.nagi4757.ec.api.order.presentation.shared.toResponse
import jakarta.validation.Valid
import org.springframework.http.HttpStatus
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PatchMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RequestParam
import org.springframework.web.bind.annotation.RestController
import org.springframework.web.server.ResponseStatusException

@RestController
@RequestMapping("/api/admin/orders")
class OrderAdminController(
    private val orderService: OrderService
) {
    /* 전체 주문 목록 (페이지네이션) */
    @GetMapping
    fun listOrders(
        @RequestParam(defaultValue = "1") page: Int,
        @RequestParam(defaultValue = "20") size: Int
    ): OrderListResponse = orderService.listAllOrders(page, size).toResponse()

    /* 주문 상세 */
    @GetMapping("/{id}")
    fun getOrder(@PathVariable id: Long): OrderResponse =
        orderService.getOrderAdmin(id).toResponse()

    /* 주문 상태 변경 */
    @PatchMapping("/{id}/status")
    fun updateStatus(
        @PathVariable id: Long,
        @Valid @RequestBody req: OrderRequest.UpdateStatus
    ): OrderResponse {
        val status = runCatching { OrderStatus.valueOf(req.status) }.getOrNull()
            ?: throw ResponseStatusException(HttpStatus.BAD_REQUEST, "Invalid status: ${req.status}")
        return orderService.updateStatus(id, status).toResponse()
    }
}

