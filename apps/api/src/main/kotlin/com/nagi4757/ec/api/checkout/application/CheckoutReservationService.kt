package com.nagi4757.ec.api.checkout.application

import com.nagi4757.ec.api.auth.domain.repository.UserRepository
import com.nagi4757.ec.api.cart.application.CartService
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.EmptyCartException
import com.nagi4757.ec.api.common.error.InsufficientStockException
import com.nagi4757.ec.api.common.error.PaymentAttemptInProgressException
import com.nagi4757.ec.api.common.error.ProductNotAvailableException
import com.nagi4757.ec.api.common.error.ResourceNotFoundException
import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderItem
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.domain.repository.OrderRepository
import com.nagi4757.ec.api.payment.domain.model.PaymentAttempt
import com.nagi4757.ec.api.payment.domain.repository.PaymentAttemptRepository
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Isolation
import org.springframework.transaction.annotation.Transactional

/**
 * T1. Turns the live cart into an immutable order snapshot that holds stock, and
 * opens a payment attempt against it.
 *
 * Nothing here talks to the payment gateway: an external call inside a database
 * transaction would hold row locks for the duration of a network round trip and
 * could not be rolled back anyway.
 *
 * The cart is deliberately left alone. It is only trimmed once a charge has
 * actually succeeded, so a declined payment leaves the customer's basket intact.
 */
@Service
class CheckoutReservationService(
    private val userRepository: UserRepository,
    private val cartService: CartService,
    private val productRepository: ProductRepository,
    private val orderRepository: OrderRepository,
    private val paymentAttemptRepository: PaymentAttemptRepository
) {
    @Transactional(isolation = Isolation.READ_COMMITTED)
    fun reserve(command: CheckoutCommand): ReserveOutcome {
        // Serialise this customer's checkouts before reading anything. Two requests
        // that both look for an in-flight payment and both find none would each start
        // a charge; the lock is what makes that read trustworthy. Every new checkout
        // passes through here, so a second tab, a client without session storage and a
        // direct API call are all covered.
        check(userRepository.lockForUpdate(command.userId)) {
            // No row means no lock. Proceeding would run the guard below unserialised,
            // so the request stops rather than silently losing its protection.
            "Cannot lock user ${command.userId} for checkout; the account no longer exists"
        }

        val active = paymentAttemptRepository.findActiveByUserId(command.userId)
        if (active != null) {
            return if (active.idempotencyKey == command.idempotencyKey) {
                // The same attempt, retried. Resume it rather than reserving again.
                ReserveOutcome.Existing(active)
            } else {
                // A different payment for this customer is still unsettled. Starting a
                // second one risks charging them twice.
                throw PaymentAttemptInProgressException()
            }
        }

        val cart = cartService.getCart(command.userId)
        if (cart.items.isEmpty()) throw EmptyCartException()
        if (cart.items.any { !it.available }) throw ProductNotAvailableException()

        cart.items.forEach { line ->
            if (!productRepository.decreaseStockIfAvailable(line.productId, line.quantity)) {
                throwStockUpdateFailure(line.productId)
            }
        }

        val order = orderRepository.save(
            Order(
                id = null,
                userId = command.userId,
                status = OrderStatus.PAYMENT_PENDING,
                totalAmount = cart.totalAmount,
                createdAt = null,
                shippingAddress = command.shippingAddress,
                items = cart.items.map { line ->
                    OrderItem(
                        id = null,
                        orderId = 0L,
                        productId = line.productId,
                        name = line.name,
                        price = line.price,
                        quantity = line.quantity,
                        lineAmount = line.lineAmount
                    )
                }
            )
        )
        val orderId = requireNotNull(order.id) { "Persisted order id is required" }

        val fingerprint = CheckoutRequestFingerprint.from(
            userId = command.userId,
            currency = CHECKOUT_CURRENCY,
            paymentMethodId = command.paymentMethodId,
            shippingAddress = command.shippingAddress,
            lines = order.toLineSnapshots()
        )

        // A duplicate key here means a concurrent request for the same idempotency
        // key won. The exception is allowed to propagate so this whole transaction
        // rolls back, releasing the stock it just took; the coordinator reloads the
        // winning attempt outside any transaction.
        val attempt = paymentAttemptRepository.createPending(
            idempotencyKey = command.idempotencyKey,
            requestFingerprint = fingerprint,
            amountJpy = cart.totalAmount,
            orderId = orderId
        )

        return ReserveOutcome.Reserved(
            ReservedCheckout(
                order = order,
                paymentAttemptId = requireNotNull(attempt.id) { "Persisted payment attempt id is required" },
                requestFingerprint = fingerprint,
                amountJpy = cart.totalAmount
            )
        )
    }

    private fun throwStockUpdateFailure(productId: Long): Nothing {
        val product = productRepository.findById(productId)
            ?: throw ResourceNotFoundException(ApiErrorCode.PRODUCT_NOT_FOUND)
        if (!product.active) {
            throw ProductNotAvailableException()
        }
        throw InsufficientStockException()
    }
}

/**
 * What T1 decided: either a fresh reservation, or the customer's existing unsettled
 * attempt that this request should continue.
 */
sealed interface ReserveOutcome {
    data class Reserved(val reservation: ReservedCheckout) : ReserveOutcome
    data class Existing(val attempt: PaymentAttempt) : ReserveOutcome
}

/**
 * The fingerprint inputs, taken from the stored order rather than the cart. A retry
 * recomputes the value from exactly this shape, so both paths must agree.
 */
fun Order.toLineSnapshots(): List<CheckoutLineSnapshot> = items.map { item ->
    CheckoutLineSnapshot(
        productId = item.productId,
        unitPrice = item.price,
        quantity = item.quantity
    )
}
