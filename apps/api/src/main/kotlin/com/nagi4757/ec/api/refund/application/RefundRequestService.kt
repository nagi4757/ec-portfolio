package com.nagi4757.ec.api.refund.application

import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.RefundAttemptInProgressException
import com.nagi4757.ec.api.common.error.RefundNotEligibleException
import com.nagi4757.ec.api.common.error.ResourceNotFoundException
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.domain.repository.OrderRepository
import com.nagi4757.ec.api.payment.domain.repository.PaymentAttemptRepository
import com.nagi4757.ec.api.refund.domain.repository.RefundAttemptRepository
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Isolation
import org.springframework.transaction.annotation.Transactional

/**
 * R1. Claims the order for a refund and opens a refund attempt against it.
 *
 * The lock is taken on the order, not on the customer: an operator and the customer
 * can both ask to cancel the same order, and both paths have to contend for the same
 * row so that only one refund is ever started. A user-level lock would not serialise
 * the operator path at all.
 *
 * Nothing here talks to the provider. An external call inside this transaction would
 * hold the order lock for a network round trip.
 */
@Service
class RefundRequestService(
    private val orderRepository: OrderRepository,
    private val paymentAttemptRepository: PaymentAttemptRepository,
    private val refundAttemptRepository: RefundAttemptRepository
) {
    @Transactional(isolation = Isolation.READ_COMMITTED)
    fun start(command: RefundCommand): RefundStartOutcome {
        val order = orderRepository.lockForUpdate(command.orderId)
            ?: throw ResourceNotFoundException(ApiErrorCode.ORDER_NOT_FOUND)

        // Ownership before anything else. A customer may only refund their own order;
        // a null userId means an operator is acting and the check does not apply.
        if (command.userId != null && order.userId != command.userId) {
            throw ResourceNotFoundException(ApiErrorCode.ORDER_NOT_FOUND)
        }

        val active = refundAttemptRepository.findActiveByOrderId(command.orderId)
        if (active != null) {
            return if (active.idempotencyKey == command.idempotencyKey) {
                RefundStartOutcome.Existing(active)
            } else {
                // Another refund for this order is unsettled. Starting a second one
                // could return the money twice.
                throw RefundAttemptInProgressException()
            }
        }

        // Only a paid order that has not left the warehouse. Refunding a shipped or
        // delivered order and restoring stock would claim goods are back on the shelf
        // while a customer still holds them.
        if (!order.status.isRefundable()) {
            throw RefundNotEligibleException()
        }

        // The amount and the payment reference come from the settled charge, never
        // from the request.
        val charge = paymentAttemptRepository.findSuccessfulByOrderId(command.orderId)
            ?: throw RefundNotEligibleException()
        val externalPaymentId = charge.externalPaymentId
        if (externalPaymentId.isNullOrBlank()) {
            // Guaranteed by a database CHECK, so reaching this means the invariant
            // was bypassed. Refusing is the only safe answer.
            throw RefundNotEligibleException()
        }

        val statusBefore = order.status
        check(
            orderRepository.transitionStatus(
                id = command.orderId,
                expectedStatus = statusBefore,
                targetStatus = OrderStatus.REFUND_PENDING
            )
        ) { "Order ${command.orderId} changed state while locked for refund" }

        val attempt = refundAttemptRepository.createPending(
            idempotencyKey = command.idempotencyKey,
            requestFingerprint = RefundRequestFingerprint.from(
                orderId = command.orderId,
                paymentAttemptId = requireNotNull(charge.id),
                amountJpy = charge.amountJpy
            ),
            orderId = command.orderId,
            paymentAttemptId = requireNotNull(charge.id),
            amountJpy = charge.amountJpy,
            orderStatusBefore = statusBefore
        )

        return RefundStartOutcome.Started(attempt = attempt, order = order)
    }
}
