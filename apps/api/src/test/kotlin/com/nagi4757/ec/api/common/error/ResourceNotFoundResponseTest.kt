package com.nagi4757.ec.api.common.error

import com.nagi4757.ec.api.category.application.CategoryService
import com.nagi4757.ec.api.category.presentation.admin.CategoryAdminController
import com.nagi4757.ec.api.category.presentation.public.CategoryPublicController
import com.nagi4757.ec.api.product.application.ProductService
import com.nagi4757.ec.api.product.presentation.admin.ProductAdminController
import com.nagi4757.ec.api.product.presentation.public.ProductPublicController
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.get
import org.springframework.test.web.servlet.setup.MockMvcBuilders

class ResourceNotFoundResponseTest {
    private lateinit var mockMvc: MockMvc

    @BeforeEach
    fun setUp() {
        val productService = mock(ProductService::class.java)
        val categoryService = mock(CategoryService::class.java)

        mockMvc = MockMvcBuilders
            .standaloneSetup(
                ProductPublicController(productService),
                ProductAdminController(productService),
                CategoryPublicController(categoryService),
                CategoryAdminController(categoryService)
            )
            .setControllerAdvice(GlobalExceptionHandler())
            .build()
    }

    @Test
    fun `public product lookup returns product not found response`() {
        mockMvc.get("/api/public/products/999")
            .andExpect {
                status { isNotFound() }
                jsonPath("$.code") { value("PRODUCT_NOT_FOUND") }
                jsonPath("$.path") { value("/api/public/products/999") }
            }
    }

    @Test
    fun `admin product lookup returns product not found response`() {
        mockMvc.get("/api/admin/products/999")
            .andExpect {
                status { isNotFound() }
                jsonPath("$.code") { value("PRODUCT_NOT_FOUND") }
            }
    }

    @Test
    fun `public category lookup returns category not found response`() {
        mockMvc.get("/api/public/categories/999")
            .andExpect {
                status { isNotFound() }
                jsonPath("$.code") { value("CATEGORY_NOT_FOUND") }
                jsonPath("$.path") { value("/api/public/categories/999") }
            }
    }

    @Test
    fun `admin category lookup returns category not found response`() {
        mockMvc.get("/api/admin/categories/999")
            .andExpect {
                status { isNotFound() }
                jsonPath("$.code") { value("CATEGORY_NOT_FOUND") }
            }
    }
}
