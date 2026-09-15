package com.nagi4757.ec.api

import com.nagi4757.ec.api.category.application.CategoryService
import com.nagi4757.ec.api.category.application.command.CreateCategoryCommand
import com.nagi4757.ec.api.category.domain.model.Category
import com.nagi4757.ec.api.category.presentation.admin.CategoryAdminController
import com.nagi4757.ec.api.checkout.application.CheckoutCommand
import com.nagi4757.ec.api.checkout.application.CheckoutCoordinator
import com.nagi4757.ec.api.checkout.application.CheckoutOutcome
import com.nagi4757.ec.api.checkout.application.CheckoutResult
import com.nagi4757.ec.api.checkout.presentation.CheckoutController
import com.nagi4757.ec.api.common.error.GlobalExceptionHandler
import com.nagi4757.ec.api.common.logging.CorrelationIdFilter
import com.nagi4757.ec.api.common.security.JwtUserClaims
import com.nagi4757.ec.api.order.application.OrderService
import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderItem
import com.nagi4757.ec.api.order.domain.model.OrderStatus
import com.nagi4757.ec.api.order.domain.model.ShippingAddress
import com.nagi4757.ec.api.order.presentation.user.OrderUserController
import com.nagi4757.ec.api.product.application.ProductService
import com.nagi4757.ec.api.product.application.command.CreateProductCommand
import com.nagi4757.ec.api.product.domain.model.Product
import com.nagi4757.ec.api.product.presentation.admin.ProductAdminController
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import org.springframework.http.MediaType
import org.springframework.security.core.Authentication
import org.springframework.security.core.context.SecurityContextHolder
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.delete
import org.springframework.test.web.servlet.post
import org.springframework.test.web.servlet.setup.MockMvcBuilders
import org.springframework.test.web.servlet.setup.StandaloneMockMvcBuilder

class HttpSuccessStatusContractTest {
    private lateinit var categoryService: CategoryService
    private lateinit var productService: ProductService
    private lateinit var orderService: OrderService
    private lateinit var checkoutCoordinator: CheckoutCoordinator
    private lateinit var mockMvc: MockMvc

    @BeforeEach
    fun setUp() {
        categoryService = mock(CategoryService::class.java)
        productService = mock(ProductService::class.java)
        orderService = mock(OrderService::class.java)
        checkoutCoordinator = mock(CheckoutCoordinator::class.java)
        mockMvc = MockMvcBuilders
            .standaloneSetup(
                CategoryAdminController(categoryService),
                ProductAdminController(productService),
                OrderUserController(orderService),
                CheckoutController(checkoutCoordinator)
            )
            .setControllerAdvice(GlobalExceptionHandler())
            .addFilters<StandaloneMockMvcBuilder>(CorrelationIdFilter())
            .build()

        val authentication = mock(Authentication::class.java)
        `when`(authentication.principal).thenReturn(
            JwtUserClaims(userId = USER_ID, email = "user@example.test", role = "USER")
        )
        SecurityContextHolder.getContext().authentication = authentication
    }

    @AfterEach
    fun tearDown() {
        SecurityContextHolder.clearContext()
    }

    @Test
    fun `category creation returns created with the existing response body`() {
        `when`(
            categoryService.create(
                CreateCategoryCommand(name = "Category", description = "Description")
            )
        ).thenReturn(
            Category(id = 10L, name = "Category", description = "Description")
        )

        mockMvc.post("/api/admin/categories") {
            contentType = MediaType.APPLICATION_JSON
            content = """{"name":"Category","description":"Description"}"""
        }.andExpect {
            status { isCreated() }
            content { contentTypeCompatibleWith(MediaType.APPLICATION_JSON) }
            jsonPath("$.id") { value(10) }
            jsonPath("$.name") { value("Category") }
            jsonPath("$.description") { value("Description") }
        }
    }

    @Test
    fun `category deletion returns no content with an empty response body`() {
        mockMvc.delete("/api/admin/categories/10")
            .andExpect {
                status { isNoContent() }
                content { string("") }
            }
    }

    @Test
    fun `product creation returns created with the existing response body`() {
        `when`(
            productService.create(
                CreateProductCommand(
                    name = "Product",
                    price = 1_000L,
                    stockQuantity = 5,
                    imageUrl = null,
                    description = "Description"
                )
            )
        ).thenReturn(
            Product(
                id = 20L,
                name = "Product",
                price = 1_000L,
                stockQuantity = 5,
                imageUrl = null,
                description = "Description"
            )
        )

        mockMvc.post("/api/admin/products") {
            contentType = MediaType.APPLICATION_JSON
            content = """{"name":"Product","price":1000,"stockQuantity":5,"description":"Description"}"""
        }.andExpect {
            status { isCreated() }
            content { contentTypeCompatibleWith(MediaType.APPLICATION_JSON) }
            jsonPath("$.id") { value(20) }
            jsonPath("$.name") { value("Product") }
            jsonPath("$.price") { value(1_000) }
            jsonPath("$.stockQuantity") { value(5) }
            jsonPath("$.active") { value(true) }
        }
    }

    @Test
    fun `checkout returns created with the order body when the payment succeeds`() {
        val shippingAddress = ShippingAddress(
            recipientName = "Test Recipient",
            postalCode = "100-0001",
            prefecture = "Tokyo",
            city = "Chiyoda-ku",
            addressLine1 = "Chiyoda 1-1",
            addressLine2 = null,
            phoneNumber = "03-1234-5678"
        )
        val expectedCommand = CheckoutCommand(
            userId = USER_ID,
            shippingAddress = shippingAddress,
            paymentMethodId = "mock:success",
            idempotencyKey = "contract-key-1"
        )
        `when`(checkoutCoordinator.checkout(expectedCommand)).thenReturn(
            CheckoutResult(
                outcome = CheckoutOutcome.PAID,
                order = Order(
                    id = 30L,
                    userId = USER_ID,
                    status = OrderStatus.PENDING,
                    totalAmount = 2_000L,
                    createdAt = null,
                    shippingAddress = shippingAddress,
                    items = listOf(
                        OrderItem(
                            id = 40L,
                            orderId = 30L,
                            productId = 20L,
                            name = "Product",
                            price = 1_000L,
                            quantity = 2,
                            lineAmount = 2_000L
                        )
                    )
                )
            )
        )

        mockMvc.post("/api/user/checkout") {
            contentType = MediaType.APPLICATION_JSON
            header("Idempotency-Key", "contract-key-1")
            content = validCheckoutRequest()
        }.andExpect {
            status { isCreated() }
            content { contentTypeCompatibleWith(MediaType.APPLICATION_JSON) }
            jsonPath("$.outcome") { value("PAID") }
            jsonPath("$.order.id") { value(30) }
            jsonPath("$.order.status") { value("PENDING") }
            jsonPath("$.order.totalAmount") { value(2_000) }
            jsonPath("$.order.items[0].productId") { value(20) }
            jsonPath("$.order.items[0].quantity") { value(2) }
            jsonPath("$.order.shippingAddress.recipientName") { value("Test Recipient") }
            jsonPath("$.order.shippingAddress.postalCode") { value("100-0001") }
        }
    }

    @Test
    fun `checkout rejects a missing shipping address`() {
        mockMvc.post("/api/user/checkout") {
            contentType = MediaType.APPLICATION_JSON
            header("Idempotency-Key", "contract-key-2")
            content = "{}"
        }.andExpect {
            status { isBadRequest() }
        }
    }

    @Test
    fun `checkout rejects an invalid Japanese postal code`() {
        mockMvc.post("/api/user/checkout") {
            contentType = MediaType.APPLICATION_JSON
            header("Idempotency-Key", "contract-key-3")
            content = validCheckoutRequest().replace("100-0001", "invalid")
        }.andExpect {
            status { isBadRequest() }
            jsonPath("$.code") { value("VALIDATION_FAILED") }
        }
    }

    private fun validCheckoutRequest() = """
        {
          "paymentMethodId": "mock:success",
          "shippingAddress": {
            "recipientName": "Test Recipient",
            "postalCode": "100-0001",
            "prefecture": "Tokyo",
            "city": "Chiyoda-ku",
            "addressLine1": "Chiyoda 1-1",
            "phoneNumber": "03-1234-5678"
          }
        }
    """.trimIndent()

    companion object {
        private const val USER_ID = 1L
    }
}
