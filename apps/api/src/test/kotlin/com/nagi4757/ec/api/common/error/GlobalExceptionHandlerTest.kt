package com.nagi4757.ec.api.common.error

import jakarta.validation.Valid
import jakarta.validation.constraints.NotBlank
import org.hamcrest.Matchers.aMapWithSize
import org.hamcrest.Matchers.containsString
import org.hamcrest.Matchers.not
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.http.HttpStatus
import org.springframework.http.MediaType
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.get
import org.springframework.test.web.servlet.post
import org.springframework.test.web.servlet.setup.MockMvcBuilders
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.server.ResponseStatusException

class GlobalExceptionHandlerTest {
    private lateinit var mockMvc: MockMvc

    @BeforeEach
    fun setUp() {
        mockMvc = MockMvcBuilders
            .standaloneSetup(TestController())
            .setControllerAdvice(GlobalExceptionHandler())
            .build()
    }

    @Test
    fun `application exception returns common error response`() {
        mockMvc.get("/test/not-found")
            .andExpect {
                status { isNotFound() }
                content { contentType(MediaType.APPLICATION_JSON) }
                jsonPath("$.status") { value(404) }
                jsonPath("$.code") { value("PRODUCT_NOT_FOUND") }
                jsonPath("$.message") { value("Product was not found") }
                jsonPath("$.path") { value("/test/not-found") }
                jsonPath("$.timestamp") { exists() }
                jsonPath("$.fieldErrors") { isArray() }
                jsonPath("$.fieldErrors") { isEmpty() }
            }
    }

    @Test
    fun `insufficient stock returns conflict response`() {
        mockMvc.get("/test/insufficient-stock")
            .andExpect {
                status { isConflict() }
                jsonPath("$.status") { value(409) }
                jsonPath("$.code") { value("INSUFFICIENT_STOCK") }
                jsonPath("$.message") { value("Product stock is insufficient") }
            }
    }

    @Test
    fun `validation failure includes field errors`() {
        mockMvc.post("/test/validation") {
            contentType = MediaType.APPLICATION_JSON
            content = """{"name":""}"""
        }.andExpect {
            status { isBadRequest() }
            jsonPath("$.code") { value("VALIDATION_FAILED") }
            jsonPath("$.fieldErrors[0].field") { value("name") }
            jsonPath("$.fieldErrors[0].code") { value("NotBlank") }
            jsonPath("$.fieldErrors[0].message") { exists() }
        }
    }

    @Test
    fun `malformed json returns safe error response`() {
        mockMvc.post("/test/validation") {
            contentType = MediaType.APPLICATION_JSON
            content = """{"name":"""
        }.andExpect {
            status { isBadRequest() }
            jsonPath("$.code") { value("MALFORMED_REQUEST") }
            jsonPath("$.message") { value("Malformed request") }
        }
    }

    @Test
    fun `response status exception preserves bad request status without exposing reason`() {
        assertSafeResponseStatus(
            path = "/test/response-status/400",
            expectedStatus = 400,
            expectedCode = "BAD_REQUEST",
            expectedMessage = "Bad request"
        )
    }

    @Test
    fun `response status exception preserves unauthorized status without exposing reason`() {
        assertSafeResponseStatus(
            path = "/test/response-status/401",
            expectedStatus = 401,
            expectedCode = "UNAUTHORIZED",
            expectedMessage = "Authentication is required"
        )
    }

    @Test
    fun `response status exception preserves not found status without exposing reason`() {
        assertSafeResponseStatus(
            path = "/test/response-status/404",
            expectedStatus = 404,
            expectedCode = "RESOURCE_NOT_FOUND",
            expectedMessage = "Resource was not found"
        )
    }

    @Test
    fun `response status exception preserves conflict status without exposing reason`() {
        assertSafeResponseStatus(
            path = "/test/response-status/409",
            expectedStatus = 409,
            expectedCode = "CONFLICT",
            expectedMessage = "Request conflicts with the current resource state"
        )
    }

    @Test
    fun `unexpected exception does not expose internal message`() {
        mockMvc.get("/test/unexpected")
            .andExpect {
                status { isInternalServerError() }
                jsonPath("$.timestamp") { exists() }
                jsonPath("$.status") { value(500) }
                jsonPath("$.code") { value("INTERNAL_SERVER_ERROR") }
                jsonPath("$.message") { value("An unexpected error occurred") }
                jsonPath("$.path") { value("/test/unexpected") }
                jsonPath("$.fieldErrors") { isEmpty() }
                jsonPath("$") { value(aMapWithSize<String, Any>(6)) }
                jsonPath("$.exception") { doesNotExist() }
                jsonPath("$.cause") { doesNotExist() }
                jsonPath("$.stackTrace") { doesNotExist() }
                content { string(not(containsString("database password"))) }
                content { string(not(containsString("IllegalStateException"))) }
            }
    }

    private fun assertSafeResponseStatus(
        path: String,
        expectedStatus: Int,
        expectedCode: String,
        expectedMessage: String
    ) {
        mockMvc.get(path)
            .andExpect {
                status { isEqualTo(expectedStatus) }
                jsonPath("$.status") { value(expectedStatus) }
                jsonPath("$.code") { value(expectedCode) }
                jsonPath("$.message") { value(expectedMessage) }
                jsonPath("$.path") { value(path) }
                content { string(not(containsString("sensitive reason"))) }
            }
    }

    @RestController
    @RequestMapping("/test")
    class TestController {
        @GetMapping("/not-found")
        fun notFound(): Nothing =
            throw ResourceNotFoundException(ApiErrorCode.PRODUCT_NOT_FOUND)

        @GetMapping("/insufficient-stock")
        fun insufficientStock(): Nothing = throw InsufficientStockException()

        @PostMapping("/validation")
        fun validate(@Valid @RequestBody request: TestRequest): TestRequest = request

        @GetMapping("/unexpected")
        fun unexpected(): Nothing =
            throw IllegalStateException("database password must not be exposed")

        @GetMapping("/response-status/{status}")
        fun responseStatus(@PathVariable status: Int): Nothing =
            throw ResponseStatusException(HttpStatus.valueOf(status), "sensitive reason")
    }

    data class TestRequest(
        @field:NotBlank val name: String
    )
}
