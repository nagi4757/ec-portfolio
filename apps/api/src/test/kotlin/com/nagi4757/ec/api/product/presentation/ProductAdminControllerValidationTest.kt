package com.nagi4757.ec.api.product.presentation

import com.nagi4757.ec.api.common.error.GlobalExceptionHandler
import com.nagi4757.ec.api.common.logging.CorrelationIdFilter
import com.nagi4757.ec.api.product.application.ProductService
import com.nagi4757.ec.api.product.domain.model.Product
import com.nagi4757.ec.api.product.domain.repository.ProductRepository
import com.nagi4757.ec.api.product.presentation.admin.ProductAdminController
import com.nagi4757.ec.api.product.presentation.public.ProductPublicController
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.mockito.ArgumentMatchers.anyInt
import org.mockito.ArgumentMatchers.anyLong
import org.mockito.Mockito.mock
import org.mockito.Mockito.never
import org.mockito.Mockito.verify
import org.mockito.Mockito.verifyNoInteractions
import org.mockito.Mockito.`when`
import org.springframework.http.MediaType
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.delete
import org.springframework.test.web.servlet.get
import org.springframework.test.web.servlet.patch
import org.springframework.test.web.servlet.post
import org.springframework.test.web.servlet.setup.MockMvcBuilders
import org.springframework.test.web.servlet.setup.StandaloneMockMvcBuilder

class ProductAdminControllerValidationTest {
    private lateinit var productService: ProductService
    private lateinit var mockMvc: MockMvc
    private lateinit var productRepository: ProductRepository
    private lateinit var stockContractMockMvc: MockMvc

    @BeforeEach
    fun setUp() {
        productService = mock(ProductService::class.java)
        mockMvc = mockMvcFor(productService)
        // The stock change contract belongs to the service, so these requests run
        // through a real ProductService over a mocked repository.
        productRepository = mock(ProductRepository::class.java)
        stockContractMockMvc = mockMvcFor(ProductService(productRepository))
    }

    private fun mockMvcFor(service: ProductService): MockMvc = MockMvcBuilders
        .standaloneSetup(
            ProductAdminController(service),
            ProductPublicController(service)
        )
        .setControllerAdvice(GlobalExceptionHandler())
        .addFilters<StandaloneMockMvcBuilder>(CorrelationIdFilter())
        .build()

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
    fun `update rejects negative expected stock quantity`() {
        mockMvc.patch("/api/admin/products/1") {
            contentType = MediaType.APPLICATION_JSON
            content = """{"stockQuantity":1,"expectedStockQuantity":-1}"""
        }.andExpect {
            status { isBadRequest() }
            jsonPath("$.code") { value("VALIDATION_FAILED") }
            jsonPath("$.fieldErrors[0].field") { value("expectedStockQuantity") }
            jsonPath("$.fieldErrors[0].code") { value("Min") }
        }
    }

    @Test
    fun `update without stock fields edits the product and leaves the stock alone`() {
        val current = storedProduct(stockQuantity = 5)
        `when`(productRepository.findById(1L)).thenReturn(current, current.copy(name = "Renamed"))

        stockContractMockMvc.patch("/api/admin/products/1") {
            contentType = MediaType.APPLICATION_JSON
            content = """{"name":"Renamed"}"""
        }.andExpect {
            status { isOk() }
            jsonPath("$.name") { value("Renamed") }
            jsonPath("$.stockQuantity") { value(5) }
        }

        verify(productRepository).update(current.copy(name = "Renamed"))
        verify(productRepository, never()).compareAndSetStock(anyLong(), anyInt(), anyInt())
    }

    @Test
    fun `update rejects a stock quantity sent without the expected value`() {
        // What an admin page from before this contract sends on every save.
        stockContractMockMvc.patch("/api/admin/products/1") {
            contentType = MediaType.APPLICATION_JSON
            content = """{"name":"Renamed","stockQuantity":8}"""
        }.andExpect {
            status { isBadRequest() }
            jsonPath("$.code") { value("VALIDATION_FAILED") }
        }

        verifyNoInteractions(productRepository)
    }

    @Test
    fun `update rejects an expected value sent without a stock quantity`() {
        stockContractMockMvc.patch("/api/admin/products/1") {
            contentType = MediaType.APPLICATION_JSON
            content = """{"name":"Renamed","expectedStockQuantity":5}"""
        }.andExpect {
            status { isBadRequest() }
            jsonPath("$.code") { value("VALIDATION_FAILED") }
        }

        verifyNoInteractions(productRepository)
    }

    @Test
    fun `update skips the stock write when the stock is sent unchanged`() {
        // The form still shows the five it loaded; checkout has since taken two.
        val current = storedProduct(stockQuantity = 3)
        `when`(productRepository.findById(1L)).thenReturn(current, current.copy(name = "Renamed"))

        stockContractMockMvc.patch("/api/admin/products/1") {
            contentType = MediaType.APPLICATION_JSON
            content = """{"name":"Renamed","stockQuantity":5,"expectedStockQuantity":5}"""
        }.andExpect {
            status { isOk() }
            jsonPath("$.stockQuantity") { value(3) }
        }

        verify(productRepository).update(current.copy(name = "Renamed"))
        verify(productRepository, never()).compareAndSetStock(anyLong(), anyInt(), anyInt())
    }

    @Test
    fun `update applies a stock change that still matches the expected value`() {
        val current = storedProduct(stockQuantity = 5)
        `when`(productRepository.findById(1L)).thenReturn(current, current.copy(stockQuantity = 8))
        `when`(productRepository.compareAndSetStock(1L, 5, 8)).thenReturn(true)

        stockContractMockMvc.patch("/api/admin/products/1") {
            contentType = MediaType.APPLICATION_JSON
            content = """{"stockQuantity":8,"expectedStockQuantity":5}"""
        }.andExpect {
            status { isOk() }
            jsonPath("$.stockQuantity") { value(8) }
        }

        verify(productRepository).compareAndSetStock(1L, 5, 8)
    }

    @Test
    fun `update answers a stale stock change with 409 PRODUCT_STOCK_CONFLICT`() {
        `when`(productRepository.findById(1L)).thenReturn(storedProduct(stockQuantity = 3))
        `when`(productRepository.compareAndSetStock(1L, 5, 8)).thenReturn(false)

        stockContractMockMvc.patch("/api/admin/products/1") {
            contentType = MediaType.APPLICATION_JSON
            content = """{"name":"Renamed","stockQuantity":8,"expectedStockQuantity":5}"""
        }.andExpect {
            status { isConflict() }
            jsonPath("$.code") { value("PRODUCT_STOCK_CONFLICT") }
            jsonPath("$.status") { value(409) }
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
        `when`(productService.getActive(1L)).thenReturn(product)

        mockMvc.get("/api/admin/products/1")
            .andExpect {
                status { isOk() }
                jsonPath("$.stockQuantity") { value(8) }
                jsonPath("$.active") { value(true) }
            }

        mockMvc.get("/api/public/products/1")
            .andExpect {
                status { isOk() }
                jsonPath("$.stockQuantity") { value(8) }
                jsonPath("$.active") { value(true) }
            }
    }

    @Test
    fun `delete returns no content after deactivation`() {
        mockMvc.delete("/api/admin/products/1")
            .andExpect {
                status { isNoContent() }
            }
    }

    @Test
    fun `inactive product is visible to admin but hidden from public API`() {
        val inactiveProduct = Product(
            id = 1L,
            name = "Inactive Product",
            price = 1_000L,
            stockQuantity = 8,
            imageUrl = null,
            description = null,
            active = false
        )
        `when`(productService.get(1L)).thenReturn(inactiveProduct)
        `when`(productService.getActive(1L)).thenReturn(null)

        mockMvc.get("/api/admin/products/1")
            .andExpect {
                status { isOk() }
                jsonPath("$.active") { value(false) }
            }

        mockMvc.get("/api/public/products/1")
            .andExpect {
                status { isNotFound() }
                jsonPath("$.code") { value("PRODUCT_NOT_FOUND") }
            }
    }

    private fun storedProduct(stockQuantity: Int) = Product(
        id = 1L,
        name = "Product",
        price = 1_000L,
        stockQuantity = stockQuantity,
        imageUrl = null,
        description = null
    )
}
