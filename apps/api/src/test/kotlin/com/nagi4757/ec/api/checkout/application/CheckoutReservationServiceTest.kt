package com.nagi4757.ec.api.checkout.application

import com.nagi4757.ec.api.auth.domain.model.User
import com.nagi4757.ec.api.auth.domain.repository.UserRepository
import com.nagi4757.ec.api.cart.application.CartLine
import com.nagi4757.ec.api.cart.application.CartService
import com.nagi4757.ec.api.cart.application.CartView
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ApplicationException
import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.domain.model.ShippingAddress
import com.nagi4757.ec.api.order.domain.repository.OrderRepository
import com.nagi4757.ec.api.payment.domain.model.PaymentAttempt
import com.nagi4757.ec.api.payment.domain.model.PaymentAttemptStatus
import com.nagi4757.ec.api.payment.domain.repository.AppliedPaymentResult
import com.nagi4757.ec.api.payment.domain.repository.PaymentAttemptRepository
import com.nagi4757.ec.api.product.domain.model.Product
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.verify
import org.mockito.Mockito.verifyNoInteractions
import org.mockito.Mockito.`when`
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Reservation behaviour, carried over from the order creation tests that used to
 * live on OrderService. The important difference is the last assertion in several
 * of them: reserving must not clear the cart, because the payment has not happened
 * yet and a declined charge has to leave the customer's basket intact.
 */
class CheckoutReservationServiceTest {
    @Test
    fun `reserve holds stock and creates a payment pending order without clearing the cart`() {
        val fixture = fixture()
        `when`(fixture.cartService.getCart(USER_ID)).thenReturn(cartWith(quantity = 2))
        `when`(fixture.productRepository.decreaseStockIfAvailable(PRODUCT_ID, 2)).thenReturn(true)

        val reserved = fixture.service.reserveOrFail(command())

        verify(fixture.productRepository).decreaseStockIfAvailable(PRODUCT_ID, 2)
        // The cart is only trimmed once a charge succeeds.
        verify(fixture.cartService, never()).clear(USER_ID)

        val saved = fixture.orderRepository.savedOrders.single()
        assertEquals(USER_ID, saved.userId)
        assertEquals(OrderStatus.PAYMENT_PENDING, saved.status)
        assertEquals(38_000L, saved.totalAmount)
        assertEquals(SHIPPING_ADDRESS, saved.shippingAddress)
        assertEquals(38_000L, reserved.amountJpy)
        assertNotNull(reserved.order.id)
    }

    @Test
    fun `reserve records the attempt against the order it reserved`() {
        val fixture = fixture()
        `when`(fixture.cartService.getCart(USER_ID)).thenReturn(cartWith(quantity = 2))
        `when`(fixture.productRepository.decreaseStockIfAvailable(PRODUCT_ID, 2)).thenReturn(true)

        val reserved = fixture.service.reserveOrFail(command())

        val recorded = fixture.paymentAttemptRepository.created.single()
        assertEquals(IDEMPOTENCY_KEY, recorded.idempotencyKey)
        assertEquals(38_000L, recorded.amountJpy)
        assertEquals(reserved.order.id, recorded.orderId)
        assertEquals(reserved.requestFingerprint, recorded.requestFingerprint)
    }

    @Test
    fun `reserve stores a fingerprint that the stored order reproduces exactly`() {
        val fixture = fixture()
        `when`(fixture.cartService.getCart(USER_ID)).thenReturn(cartWith(quantity = 2))
        `when`(fixture.productRepository.decreaseStockIfAvailable(PRODUCT_ID, 2)).thenReturn(true)

        val reserved = fixture.service.reserveOrFail(command())

        // A retry recomputes the fingerprint from the persisted order rather than the
        // cart, so the two derivations have to agree or every retry would 409.
        val fromStoredOrder = CheckoutRequestFingerprint.from(
            userId = reserved.order.userId,
            currency = CHECKOUT_CURRENCY,
            paymentMethodId = PAYMENT_METHOD,
            shippingAddress = requireNotNull(reserved.order.shippingAddress),
            lines = reserved.order.toLineSnapshots()
        )
        assertEquals(reserved.requestFingerprint, fromStoredOrder)
    }

    @Test
    fun `reserve rejects an empty cart`() {
        val fixture = fixture()
        `when`(fixture.cartService.getCart(USER_ID)).thenReturn(CartView(emptyList(), 0, 0))

        val exception = assertThrows(ApplicationException::class.java) {
            fixture.service.reserveOrFail(command())
        }

        assertEquals(ApiErrorCode.EMPTY_CART, exception.errorCode)
        assertEquals(0, fixture.orderRepository.savedOrders.size)
        verifyNoInteractions(fixture.productRepository)
    }

    @Test
    fun `reserve rejects an unavailable cart item before touching stock`() {
        val fixture = fixture()
        `when`(fixture.cartService.getCart(USER_ID)).thenReturn(cartWith(quantity = 2, available = false))

        val exception = assertThrows(ApplicationException::class.java) {
            fixture.service.reserveOrFail(command())
        }

        assertEquals(ApiErrorCode.PRODUCT_NOT_AVAILABLE, exception.errorCode)
        assertEquals(0, fixture.orderRepository.savedOrders.size)
        verifyNoInteractions(fixture.productRepository)
    }

    @Test
    fun `reserve reports insufficient stock without saving an order`() {
        val fixture = fixture()
        `when`(fixture.cartService.getCart(USER_ID)).thenReturn(cartWith(quantity = 2))
        `when`(fixture.productRepository.decreaseStockIfAvailable(PRODUCT_ID, 2)).thenReturn(false)
        `when`(fixture.productRepository.findById(PRODUCT_ID)).thenReturn(product(active = true))

        val exception = assertThrows(ApplicationException::class.java) {
            fixture.service.reserveOrFail(command())
        }

        assertEquals(ApiErrorCode.INSUFFICIENT_STOCK, exception.errorCode)
        assertEquals(0, fixture.orderRepository.savedOrders.size)
        assertEquals(0, fixture.paymentAttemptRepository.created.size)
    }

    @Test
    fun `reserve classifies a concurrent deactivation as product not available`() {
        val fixture = fixture()
        `when`(fixture.cartService.getCart(USER_ID)).thenReturn(cartWith(quantity = 2))
        `when`(fixture.productRepository.decreaseStockIfAvailable(PRODUCT_ID, 2)).thenReturn(false)
        `when`(fixture.productRepository.findById(PRODUCT_ID)).thenReturn(product(active = false))

        val exception = assertThrows(ApplicationException::class.java) {
            fixture.service.reserveOrFail(command())
        }

        assertEquals(ApiErrorCode.PRODUCT_NOT_AVAILABLE, exception.errorCode)
    }

    @Test
    fun `reserve classifies a missing product after a failed stock update as not found`() {
        val fixture = fixture()
        `when`(fixture.cartService.getCart(USER_ID)).thenReturn(cartWith(quantity = 2))
        `when`(fixture.productRepository.decreaseStockIfAvailable(PRODUCT_ID, 2)).thenReturn(false)
        `when`(fixture.productRepository.findById(PRODUCT_ID)).thenReturn(null)

        val exception = assertThrows(ApplicationException::class.java) {
            fixture.service.reserveOrFail(command())
        }

        assertEquals(ApiErrorCode.PRODUCT_NOT_FOUND, exception.errorCode)
    }

    @Test
    fun `reserve rechecks a key that settles while waiting for the user lock`() {
        val lockEntered = CountDownLatch(1)
        val releaseLock = CountDownLatch(1)
        val userRepository = BlockingUserRepository(lockEntered, releaseLock)
        val attemptRepository = RecordingPaymentAttemptRepository()
        val fixture = fixture(userRepository, attemptRepository)
        `when`(fixture.cartService.getCart(USER_ID)).thenReturn(CartView(emptyList(), 0, 0))

        // Both concurrent requests observed no key in the coordinator fast path.
        assertNull(attemptRepository.findByIdempotencyKey(IDEMPOTENCY_KEY))
        assertNull(attemptRepository.findByIdempotencyKey(IDEMPOTENCY_KEY))
        assertEquals(2, attemptRepository.findByKeyCalls.get())

        val executor = Executors.newSingleThreadExecutor()
        try {
            val waitingRequest = executor.submit<ReserveOutcome> {
                fixture.service.reserve(command())
            }

            assertTrue(lockEntered.await(5, TimeUnit.SECONDS), "reserve never reached the user lock")
            // The same-key lookup belongs after lock acquisition, so B cannot have
            // performed it while the test double is still holding the lock.
            assertEquals(2, attemptRepository.findByKeyCalls.get())

            // A wins the key and settles while B is waiting. Terminal attempts are
            // deliberately invisible to findActiveByUserId(), reproducing the stale
            // path that previously fell through to the now-empty cart.
            val winner = terminalAttempt()
            attemptRepository.store(winner)
            releaseLock.countDown()

            val outcome = waitingRequest.get(5, TimeUnit.SECONDS)
            assertTrue(outcome is ReserveOutcome.Existing)
            assertEquals(winner, (outcome as ReserveOutcome.Existing).attempt)
            assertEquals(3, attemptRepository.findByKeyCalls.get())
            assertEquals(0, fixture.orderRepository.savedOrders.size)
            assertEquals(0, attemptRepository.created.size)
            verifyNoInteractions(fixture.cartService, fixture.productRepository)
        } finally {
            releaseLock.countDown()
            executor.shutdownNow()
        }
    }

    private class Fixture(
        val service: CheckoutReservationService,
        val userRepository: UserRepository,
        val cartService: CartService,
        val productRepository: ProductRepository,
        val orderRepository: RecordingOrderRepository,
        val paymentAttemptRepository: RecordingPaymentAttemptRepository
    )

    private fun fixture(
        userRepository: UserRepository = RecordingUserRepository(),
        paymentAttemptRepository: RecordingPaymentAttemptRepository = RecordingPaymentAttemptRepository()
    ): Fixture {
        val cartService = mock(CartService::class.java)
        val productRepository = mock(ProductRepository::class.java)
        val orderRepository = RecordingOrderRepository()

        return Fixture(
            service = CheckoutReservationService(
                userRepository = userRepository,
                cartService = cartService,
                productRepository = productRepository,
                orderRepository = orderRepository,
                paymentAttemptRepository = paymentAttemptRepository
            ),
            userRepository = userRepository,
            cartService = cartService,
            productRepository = productRepository,
            orderRepository = orderRepository,
            paymentAttemptRepository = paymentAttemptRepository
        )
    }

    /** Unwraps the happy path; the guarded paths are asserted explicitly. */
    private fun CheckoutReservationService.reserveOrFail(command: CheckoutCommand): ReservedCheckout =
        when (val outcome = reserve(command)) {
            is ReserveOutcome.Reserved -> outcome.reservation
            is ReserveOutcome.Existing -> error("Expected a fresh reservation, got ${'$'}{outcome.attempt.idempotencyKey}")
        }

    private fun command() = CheckoutCommand(
        userId = USER_ID,
        shippingAddress = SHIPPING_ADDRESS,
        paymentMethodId = PAYMENT_METHOD,
        idempotencyKey = IDEMPOTENCY_KEY
    )

    private fun cartWith(quantity: Int, available: Boolean = true) = CartView(
        items = listOf(
            CartLine(
                productId = PRODUCT_ID,
                name = "T-Shirt",
                price = 19_000,
                stockQuantity = 10,
                imageUrl = null,
                quantity = quantity,
                lineAmount = 19_000L * quantity,
                available = available
            )
        ),
        totalQuantity = quantity,
        totalAmount = 19_000L * quantity
    )

    private fun product(active: Boolean) = Product(
        id = PRODUCT_ID,
        name = "T-Shirt",
        price = 19_000,
        stockQuantity = 10,
        imageUrl = null,
        description = null,
        active = active
    )

    private fun terminalAttempt() = PaymentAttempt(
        id = 91L,
        idempotencyKey = IDEMPOTENCY_KEY,
        requestFingerprint = "a".repeat(64),
        amountJpy = 38_000L,
        status = PaymentAttemptStatus.SUCCESS,
        externalPaymentId = "payment-91",
        orderId = 81L,
        createdAt = null,
        updatedAt = null
    )

    private companion object {
        const val USER_ID = 7L
        const val PRODUCT_ID = 101L
        const val PAYMENT_METHOD = "mock:success"
        const val IDEMPOTENCY_KEY = "checkout-key-1"

        val SHIPPING_ADDRESS = ShippingAddress(
            recipientName = "山田 太郎",
            postalCode = "100-0001",
            prefecture = "東京都",
            city = "千代田区",
            addressLine1 = "千代田1-1",
            addressLine2 = null,
            phoneNumber = "03-1234-5678"
        )
    }
}

/** Assigns ids the way the database would, and keeps what was written. */
class RecordingOrderRepository : OrderRepository {
    val savedOrders = mutableListOf<Order>()
    private val stored = mutableMapOf<Long, Order>()
    private var nextId = 1L

    override fun save(order: Order): Order {
        val persisted = order.copy(
            id = nextId++,
            items = order.items.map { it.copy(orderId = nextId - 1) }
        )
        savedOrders += persisted
        stored[requireNotNull(persisted.id)] = persisted
        return persisted
    }

    override fun findById(id: Long): Order? = stored[id]

    override fun findByIdAndUserId(id: Long, userId: Long): Order? =
        stored[id]?.takeIf { it.userId == userId }

    override fun findByUserId(userId: Long): List<Order> = stored.values.filter { it.userId == userId }

    override fun findAll(page: Int, size: Int) =
        com.nagi4757.ec.api.order.domain.repository.OrderPage(stored.values.toList(), page, size, 0L, 0)

    override fun transitionStatus(id: Long, expectedStatus: OrderStatus, targetStatus: OrderStatus): Boolean {
        val current = stored[id] ?: return false
        if (current.status != expectedStatus) return false
        stored[id] = current.copy(status = targetStatus)
        return true
    }

    override fun transitionStatusForUser(
        id: Long,
        userId: Long,
        expectedStatus: OrderStatus,
        targetStatus: OrderStatus
    ): Boolean {
        val current = stored[id] ?: return false
        if (current.userId != userId) return false
        return transitionStatus(id, expectedStatus, targetStatus)
    }
}

class RecordingUserRepository : UserRepository {
    var locked: Long? = null

    override fun findById(id: Long): User? = null
    override fun findByEmail(email: String): User? = null
    override fun create(user: User): Long = error("not used")

    override fun lockForUpdate(id: Long): Boolean {
        locked = id
        return true
    }
}

private class BlockingUserRepository(
    private val lockEntered: CountDownLatch,
    private val releaseLock: CountDownLatch
) : UserRepository {
    override fun findById(id: Long): User? = null
    override fun findByEmail(email: String): User? = null
    override fun create(user: User): Long = error("not used")

    override fun lockForUpdate(id: Long): Boolean {
        lockEntered.countDown()
        check(releaseLock.await(5, TimeUnit.SECONDS)) { "test did not release the user lock" }
        return true
    }
}

class RecordingPaymentAttemptRepository : PaymentAttemptRepository {
    val created = mutableListOf<PaymentAttempt>()
    val findByKeyCalls = AtomicInteger()
    private val byKey = mutableMapOf<String, PaymentAttempt>()
    private var nextId = 1L

    override fun createPending(
        idempotencyKey: String,
        requestFingerprint: String,
        amountJpy: Long,
        orderId: Long
    ): PaymentAttempt {
        val attempt = PaymentAttempt(
            id = nextId++,
            idempotencyKey = idempotencyKey,
            requestFingerprint = requestFingerprint,
            amountJpy = amountJpy,
            status = PaymentAttemptStatus.PENDING,
            externalPaymentId = null,
            orderId = orderId,
            createdAt = null,
            updatedAt = null
        )
        created += attempt
        byKey[idempotencyKey] = attempt
        return attempt
    }

    override fun findByIdempotencyKey(idempotencyKey: String): PaymentAttempt? {
        findByKeyCalls.incrementAndGet()
        return byKey[idempotencyKey]
    }

    fun store(attempt: PaymentAttempt) {
        byKey[attempt.idempotencyKey] = attempt
    }

    override fun findActiveByUserId(userId: Long): PaymentAttempt? =
        byKey.values.firstOrNull { !it.status.isTerminal() }

    override fun applyResult(
        id: Long,
        status: PaymentAttemptStatus,
        externalPaymentId: String?
    ): AppliedPaymentResult {
        val existing = byKey.values.first { it.id == id }
        if (existing.status.isTerminal()) {
            return AppliedPaymentResult(attempt = existing, applied = false)
        }
        val updated = existing.copy(status = status, externalPaymentId = externalPaymentId)
        byKey[existing.idempotencyKey] = updated
        return AppliedPaymentResult(attempt = updated, applied = true)
    }
}
