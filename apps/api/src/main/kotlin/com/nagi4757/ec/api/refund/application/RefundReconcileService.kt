package com.nagi4757.ec.api.refund.application

import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ResourceNotFoundException
import com.nagi4757.ec.api.order.domain.repository.OrderRepository
import com.nagi4757.ec.api.refund.domain.model.RefundAttempt
import com.nagi4757.ec.api.refund.domain.repository.RefundAttemptRepository
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Isolation
import org.springframework.transaction.annotation.Transactional

/**
 * R0. Finds the refund an order already has so a caller can resume it.
 *
 * This exists because the idempotency key lives on the client. A customer who
 * refunds from one tab and then loses it -- a different device, a cleared session --
 * cannot name the key any more, and a fresh key is refused because the order still
 * has an unsettled refund. Without a server-side way back in, that refund can never
 * be finished by the person it belongs to.
 *
 * Nothing here starts a refund. It reads the attempt the order already has and hands
 * it to the same orchestration a retry would take. If there is no attempt, that is
 * the answer: inventing one would turn "resume my refund" into "refund me", which is
 * a decision only an explicit refund request may make.
 *
 * The order row lock is taken for the same reason R1 takes it. Attempts are only
 * created under that lock, so holding it means the attempt read here is still the
 * order's newest when the caller acts on it.
 *
 * Nothing here talks to the provider: an external call would hold the order lock for
 * a network round trip.
 */
@Service
class RefundReconcileService(
    private val orderRepository: OrderRepository,
    private val refundAttemptRepository: RefundAttemptRepository
) {
    @Transactional(isolation = Isolation.READ_COMMITTED)
    fun load(command: RefundReconcileCommand): RefundAttempt? {
        val order = orderRepository.lockForUpdate(command.orderId)
            ?: throw ResourceNotFoundException(ApiErrorCode.ORDER_NOT_FOUND)

        // Ownership before anything else, and reported as "not found" rather than
        // "forbidden": confirming the order exists would tell a stranger which order
        // ids are real. A null userId means an operator is acting, and an operator
        // may reconcile any order including a refund the customer started.
        if (command.userId != null && order.userId != command.userId) {
            throw ResourceNotFoundException(ApiErrorCode.ORDER_NOT_FOUND)
        }

        return refundAttemptRepository.findLatestByOrderId(command.orderId)
    }
}
