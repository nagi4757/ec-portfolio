package com.nagi4757.ec.api.product.presentation

import com.nagi4757.ec.api.common.error.GlobalExceptionHandler
import com.nagi4757.ec.api.product.application.ProductService
import com.nagi4757.ec.api.product.domain.model.Product
import com.nagi4757.ec.api.product.presentation.admin.ProductAdminController
import com.nagi4757.ec.api.product.presentation.public.ProductPublicController
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import org.springframework.http.MediaType
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.get
import org.springframework.test.web.servlet.patch
import org.springframework.test.web.servlet.post
import org.springframework.test.web.servlet.setup.MockMvcBuilders

class ProductAdminControllerValidationTest {
    private lateinit var productService: ProductService
    private lateinit var mockMvc: MockMvc

    @BeforeEach
    fun setUp() {
        productService = mock(ProductService::class.java)
        mockMvc = MockMvcBuilders
            .standaloneSetup(
                ProductAdminController(productService),
                ProductPublicController(productService)
            )
            .setControllerAdvice(GlobalExceptionHandler())
            .build()
    }

    @Test
    fun `create requires stock quantity`() {
        mockMvc.post("/api/admin/products") {
            contentType = MediaType.APPLICATION_JSON
            content = """{"name":"Product","price":1000}"""
        }.andExpect {
            status { isBadRequest() }
            jsonPath("$.code") { value("VALIDATION_FAILED") }
            jsonPath("$.fieldErrors[0].field") { value("stockQuantity") }
            jsonPath("$.fieldErrors[0].code") { value("NotNull") }
        }
    }

    @Test
    fun `create rejects negative stock quantity`() {
        mockMvc.post("/api/admin/products") {
            contentType = MediaType.APPLICATION_JSON
            content = """{"name":"Product","price":1000,"stockQuantity":-1}"""
        }.andExpect {
            status { isBadRequest() }
            jsonPath("$.code") { value("VALIDATION_FAILED") }
            jsonPath("$.fieldErrors[0].field") { value("stockQuantity") }
            jsonPath("$.fieldErrors[0].code") { value("Min") }
        }
    }

    @Test
    fun `update rejects negative stock quantity`() {
        mockMvc.patch("/api/admin/products/1") {
            contentType = MediaType.APPLICATION_JSON
            content = """{"stockQuantity":-1}"""
        }.andExpect {
            status { isBadRequest() }
            jsonPath("$.code") { value("VALIDATION_FAILED") }
            jsonPath("$.fieldErrors[0].field") { value("stockQuantity") }
            jsonPath("$.fieldErrors[0].code") { value("Min") }
        }
    }

    @Test
    fun `admin and public product APIs return stock quantity`() {
        val product = Product(
            id = 1L,
            name = "Product",
            price = 1_000L,
            stockQuantity = 8,
            imageUrl = null,
            description = null
        )
        `when`(productService.get(1L)).thenReturn(product)

        mockMvc.get("/api/admin/products/1")
            .andExpect {
                status { isOk() }
                jsonPath("$.stockQuantity") { value(8) }
            }

        mockMvc.get("/api/public/products/1")
            .andExpect {
                status { isOk() }
                jsonPath("$.stockQuantity") { value(8) }
            }
    }
}
