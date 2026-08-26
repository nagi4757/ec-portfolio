package com.nagi4757.ec.api

import com.nagi4757.ec.api.category.application.CategoryService
import com.nagi4757.ec.api.category.application.command.CreateCategoryCommand
import com.nagi4757.ec.api.category.domain.model.Category
import com.nagi4757.ec.api.category.presentation.admin.CategoryAdminController
import com.nagi4757.ec.api.common.error.GlobalExceptionHandler
import com.nagi4757.ec.api.common.logging.CorrelationIdFilter
import com.nagi4757.ec.api.common.security.JwtUserClaims
import com.nagi4757.ec.api.order.application.OrderService
import com.nagi4757.ec.api.order.domain.model.Order
import com.nagi4757.ec.api.order.domain.model.OrderItem
import com.nagi4757.ec.api.order.domain.model.OrderStatus
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
    private lateinit var mockMvc: MockMvc

    @BeforeEach
    fun setUp() {
        categoryService = mock(CategoryService::class.java)
        productService = mock(ProductService::class.java)
        orderService = mock(OrderService::class.java)
        mockMvc = MockMvcBuilders
            .standaloneSetup(
                CategoryAdminController(categoryService),
                ProductAdminController(productService),
                OrderUserController(orderService)
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
    fun `order creation returns created with the existing response body`() {
        `when`(orderService.placeOrder(USER_ID)).thenReturn(
            Order(
                id = 30L,
                userId = USER_ID,
                status = OrderStatus.PENDING,
                totalAmount = 2_000L,
                createdAt = null,
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

        mockMvc.post("/api/user/orders") {
            contentType = MediaType.APPLICATION_JSON
            content = "{}"
        }.andExpect {
            status { isCreated() }
            content { contentTypeCompatibleWith(MediaType.APPLICATION_JSON) }
            jsonPath("$.id") { value(30) }
            jsonPath("$.status") { value("PENDING") }
            jsonPath("$.totalAmount") { value(2_000) }
            jsonPath("$.items[0].productId") { value(20) }
            jsonPath("$.items[0].quantity") { value(2) }
        }
    }

    companion object {
        private const val USER_ID = 1L
    }
}
