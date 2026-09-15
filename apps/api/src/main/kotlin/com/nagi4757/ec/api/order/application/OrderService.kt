package com.nagi4757.ec.api.order.application

import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.InvalidOrderTransitionException
import com.nagi4757.ec.api.common.error.OrderCancellationRequiresRefundException
import com.nagi4757.ec.api.common.error.ResourceNotFoundException
import com.nagi4757.ec.api.order.application.query.OrderQueryRepository
import com.nagi4757.ec.api.order.application.query.OrderSummary
import com.nagi4757.ec.api.order.application.query.OrderSummaryPage
import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.domain.repository.OrderRepository
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional

/**
 * Reads and lifecycle transitions for existing orders.
 *
 * Orders are no longer created here. Creation reserves stock and takes a payment,
 * which is orchestrated by
 * [com.nagi4757.ec.api.checkout.application.CheckoutCoordinator]; leaving a second
 * entry point would let a caller create an order without paying for it.
 */
@Service
class OrderService(
    private val orderRepository: OrderRepository,
    private val orderQueryRepository: OrderQueryRepository
) {
    /* 내 주문 목록 */
    fun getOrders(userId: Long): List<OrderSummary> = orderQueryRepository.findSummariesByUserId(userId)

    /* 내 주문 상세 */
    fun getOrder(userId: Long, orderId: Long): Order =
        orderRepository.findByIdAndUserId(orderId, userId)
            ?: throw ResourceNotFoundException(ApiErrorCode.ORDER_NOT_FOUND)

    /**
     * Customer cancellation is closed in every state.
     *
     * A paid order would need its money returned, and refund orchestration does not
     * exist yet; cancelling without it would leave the customer charged for an order
     * that no longer exists. A reserved order has an unresolved payment, so it cannot
     * be cancelled either. The endpoint remains so clients are told precisely why,
     * rather than being given a 404.
     */
    fun cancelOrder(userId: Long, orderId: Long): Order {
        val order = orderRepository.findByIdAndUserId(orderId, userId)
            ?: throw ResourceNotFoundException(ApiErrorCode.ORDER_NOT_FOUND)

        if (order.status.isPaid()) {
            throw OrderCancellationRequiresRefundException()
        }
        throw InvalidOrderTransitionException()
    }

    /* 어드민: 전체 주문 목록 */
    fun listAllOrders(page: Int, size: Int): OrderSummaryPage = orderQueryRepository.findSummaryPage(page, size)

    /* 어드민: 주문 상세 */
    fun getOrderAdmin(orderId: Long): Order =
        orderRepository.findById(orderId)
            ?: throw ResourceNotFoundException(ApiErrorCode.ORDER_NOT_FOUND)

    /**
     * 어드민: 주문 상태 변경.
     *
     * No stock restoration happens here any more: [OrderStatus.canTransitionTo] no
     * longer permits CANCELLED from any operator-reachable state, so the only
     * cancellation left is the checkout compensation path, which returns the stock
     * itself.
     */
    @Transactional
    fun updateStatus(orderId: Long, targetStatus: OrderStatus): Order {
        val order = orderRepository.findById(orderId)
            ?: throw ResourceNotFoundException(ApiErrorCode.ORDER_NOT_FOUND)
        if (!order.status.canTransitionTo(targetStatus)) {
            throw InvalidOrderTransitionException()
        }
        if (!orderRepository.transitionStatus(orderId, order.status, targetStatus)) {
            throw InvalidOrderTransitionException()
        }
        return getOrderAdmin(orderId)
    }
}
