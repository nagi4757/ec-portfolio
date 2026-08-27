package com.nagi4757.ec.api.common.config

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.logging.CorrelationIdContext
import org.apache.ibatis.mapping.Environment
import org.apache.ibatis.session.Configuration
import org.apache.ibatis.session.SqlSessionFactory
import org.apache.ibatis.transaction.jdbc.JdbcTransactionFactory
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.test.context.TestConfiguration
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Import
import org.springframework.core.env.MapPropertySource
import org.springframework.core.env.MutablePropertySources
import org.springframework.core.env.PropertySourcesPropertyResolver
import org.springframework.core.io.ClassPathResource
import org.springframework.core.io.support.ResourcePropertySource
import org.springframework.http.MediaType
import org.springframework.test.context.ActiveProfiles
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.get
import javax.sql.DataSource

@ActiveProfiles("test")
@SpringBootTest(
    webEnvironment = SpringBootTest.WebEnvironment.MOCK,
    properties = ["app.openapi.enabled=true"]
)
@AutoConfigureMockMvc
@Import(OpenApiTestConfig::class)
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class OpenApiDocumentationTest(
    @Autowired private val mockMvc: MockMvc,
    @Autowired private val objectMapper: ObjectMapper
) {
    private lateinit var document: JsonNode

    @BeforeAll
    fun loadOpenApiDocument() {
        val result = mockMvc.get("/v3/api-docs")
            .andExpect {
                status { isOk() }
                content { contentTypeCompatibleWith(MediaType.APPLICATION_JSON) }
            }
            .andReturn()

        document = objectMapper.readTree(result.response.contentAsString)
    }

    @Test
    fun `document contains exactly the business API operations without actuator paths`() {
        assertTrue(document.path("openapi").asText().matches(Regex("^3\\.1\\.\\d+$")))
        assertEquals(29, operations().size)
        assertTrue(document.path("paths").fieldNames().asSequence().all { it.startsWith("/api/") })
        assertFalse(document.path("paths").has("/actuator/health"))
        assertFalse(document.path("paths").has("/actuator/health/liveness"))
        assertFalse(document.path("paths").has("/actuator/health/readiness"))

        val operationIds = operations().map { it.path("operationId").asText() }
        assertEquals(operationIds.size, operationIds.distinct().size)
        assertEquals("getPublicProduct", operation("/api/public/products/{id}", "get").path("operationId").asText())
        assertEquals("getAdminOrder", operation("/api/admin/orders/{id}", "get").path("operationId").asText())
    }

    @Test
    fun `document exposes the expected tags and bearer security requirements`() {
        val expectedTags = setOf(
            "Public - Auth",
            "Public - Categories",
            "Public - Products",
            "User - Auth",
            "User - Cart",
            "User - Orders",
            "Admin - Categories",
            "Admin - Products",
            "Admin - Orders"
        )
        val actualTags = document.path("tags").map { it.path("name").asText() }.toSet()
        assertEquals(expectedTags, actualTags)

        val bearerAuth = document.path("components").path("securitySchemes").path("bearerAuth")
        assertEquals("http", bearerAuth.path("type").asText())
        assertEquals("bearer", bearerAuth.path("scheme").asText())
        assertEquals("JWT", bearerAuth.path("bearerFormat").asText())

        assertFalse(operation("/api/public/products", "get").has("security"))
        assertFalse(document.path("paths").has("/api/public/auth/me"))
        assertBearerAuth(operation("/api/user/auth/me", "get"))
        assertEquals(
            listOf("User - Auth"),
            operation("/api/user/auth/me", "get").path("tags").map { it.asText() }
        )
        assertFalse(operation("/api/public/auth/signup", "post").has("security"))
        assertFalse(operation("/api/public/auth/login", "post").has("security"))
        assertBearerAuth(operation("/api/user/cart", "get"))
        assertBearerAuth(operation("/api/admin/products", "get"))
    }

    @Test
    fun `document reuses the common error schemas and actual error codes`() {
        val schemas = document.path("components").path("schemas")
        val errorSchema = schemas.path("ApiErrorResponse")
        assertFalse(errorSchema.isMissingNode)
        assertFalse(schemas.path("ApiFieldError").isMissingNode)
        assertEquals("uuid", errorSchema.path("properties").path("correlationId").path("format").asText())

        val documentedCodes = errorSchema.path("properties").path("code").path("enum").map { it.asText() }
        assertEquals(ApiErrorCode.entries.map { it.name }, documentedCodes)

        val cartConflict = operation("/api/user/cart/items", "post").path("responses").path("409")
        assertTrue(cartConflict.path("description").asText().contains("PRODUCT_NOT_AVAILABLE"))
        assertTrue(cartConflict.path("description").asText().contains("INSUFFICIENT_STOCK"))
        assertErrorSchemaReference(cartConflict)

        val orderCancelConflict = operation("/api/user/orders/{id}/cancel", "post").path("responses").path("409")
        assertEquals("INVALID_ORDER_TRANSITION", orderCancelConflict.path("description").asText())

        val productNotFound = operation("/api/public/products/{id}", "get").path("responses").path("404")
        assertEquals("PRODUCT_NOT_FOUND", productNotFound.path("description").asText())
    }

    @Test
    fun `correlation ID is documented for requests and every documented response`() {
        val correlationParameter = document.path("components").path("parameters").path("CorrelationId")
        assertEquals(CorrelationIdContext.HEADER_NAME, correlationParameter.path("name").asText())
        assertEquals("header", correlationParameter.path("in").asText())
        assertFalse(correlationParameter.path("required").asBoolean())
        assertEquals("uuid", correlationParameter.path("schema").path("format").asText())
        assertTrue(correlationParameter.path("description").asText().contains("replaces an invalid value"))

        operations().forEach { operation ->
            assertTrue(
                operation.path("parameters").any {
                    it.path("\$ref").asText() == "#/components/parameters/CorrelationId"
                }
            )
            operation.path("responses").forEach { response ->
                assertEquals(
                    "#/components/headers/CorrelationId",
                    response.path("headers").path(CorrelationIdContext.HEADER_NAME).path("\$ref").asText()
                )
            }
        }
    }

    @Test
    fun `create operations reference distinct request schemas`() {
        val schemas = document.path("components").path("schemas")
        val orderCreateRef = requestSchemaRef("/api/user/orders", "post")
        val productCreateRef = requestSchemaRef("/api/admin/products", "post")
        val categoryCreateRef = requestSchemaRef("/api/admin/categories", "post")
        assertEquals("#/components/schemas/CreateOrderRequest", orderCreateRef)
        assertEquals("#/components/schemas/CreateProductRequest", productCreateRef)
        assertEquals("#/components/schemas/CreateCategoryRequest", categoryCreateRef)
        assertTrue(schemas.path(schemaName(orderCreateRef)).path("properties").has("shippingAddress"))
        assertTrue(schemas.path(schemaName(productCreateRef)).path("properties").has("name"))
        assertTrue(schemas.path(schemaName(productCreateRef)).path("properties").has("price"))
        assertTrue(schemas.path(schemaName(productCreateRef)).path("properties").has("stockQuantity"))
        assertTrue(schemas.path(schemaName(categoryCreateRef)).path("properties").has("name"))

        val shippingRequest = schemas.path("ShippingAddressRequest").path("properties")
        assertEquals("^\\d{3}-?\\d{4}$", shippingRequest.path("postalCode").path("pattern").asText())
        assertEquals(100, shippingRequest.path("recipientName").path("maxLength").asInt())
    }

    @Test
    fun `legacy shipping address is nullable only in order detail schema`() {
        val schemas = document.path("components").path("schemas")
        val shippingResponse = schemas.path("OrderResponse").path("properties").path("shippingAddress")
        val union = shippingResponse.path("oneOf")

        assertFalse(shippingResponse.has("\$ref"))
        assertFalse(shippingResponse.has("type"))
        assertEquals(2, union.size())
        assertEquals("#/components/schemas/ShippingAddressResponse", union[0].path("\$ref").asText())
        assertEquals("null", union[1].path("type").asText())
        assertTrue(schemas.path("OrderSummaryResponse").path("properties").path("shippingAddress").isMissingNode)
    }

    @Test
    fun `product cart and order schemas reflect the current API contract`() {
        val schemas = document.path("components").path("schemas")
        val expectedStatuses = listOf("PENDING", "PREPARING", "SHIPPED", "DELIVERED", "CANCELLED")
        assertEquals(expectedStatuses, schemas.path("OrderResponse").path("properties").path("status").path("enum").map { it.asText() })
        assertEquals(expectedStatuses, schemas.path("UpdateStatus").path("properties").path("status").path("enum").map { it.asText() })

        assertFalse(schemas.path("ProductResponse").path("properties").path("active").isMissingNode)
        assertFalse(schemas.path("ProductResponse").path("properties").path("stockQuantity").isMissingNode)
        assertFalse(schemas.path("CartItemResponse").path("properties").path("available").isMissingNode)
        assertFalse(schemas.path("CartItemResponse").path("properties").path("stockQuantity").isMissingNode)

        assertTrue(operation("/api/public/auth/signup", "post").path("responses").has("201"))
        assertTrue(operation("/api/admin/categories", "post").path("responses").has("201"))
        assertTrue(operation("/api/admin/categories/{id}", "delete").path("responses").has("204"))
        assertTrue(operation("/api/admin/products", "post").path("responses").has("201"))
        assertTrue(operation("/api/user/orders", "post").path("responses").has("201"))
        assertTrue(operation("/api/user/orders", "post").path("responses").has("400"))
        assertTrue(operation("/api/admin/products/{id}", "delete").path("responses").has("204"))
    }

    @Test
    fun `documentation endpoints are public only in an enabled context without changing API security`() {
        mockMvc.get("/v3/api-docs/swagger-config")
            .andExpect { status { isOk() } }
        mockMvc.get("/v3/api-docs.yaml")
            .andExpect { status { isOk() } }
        mockMvc.get("/swagger-ui.html")
            .andExpect { status { is3xxRedirection() } }

        mockMvc.get("/api/user/cart")
            .andExpect { status { isUnauthorized() } }
        mockMvc.get("/api/admin/products")
            .andExpect { status { isUnauthorized() } }
        mockMvc.get("/actuator/health")
            .andExpect { status { isOk() } }
    }

    private fun operation(path: String, method: String): JsonNode =
        document.path("paths").path(path).path(method)

    private fun requestSchemaRef(path: String, method: String): String =
        operation(path, method)
            .path("requestBody")
            .path("content")
            .path(MediaType.APPLICATION_JSON_VALUE)
            .path("schema")
            .path("\$ref")
            .asText()

    private fun schemaName(reference: String): String = reference.substringAfterLast('/')

    private fun operations(): List<JsonNode> =
        document.path("paths").properties().asSequence().flatMap { (_, pathItem) ->
            pathItem.properties().asSequence()
                .filter { (method, _) -> method in HTTP_METHODS }
                .map { it.value }
        }.toList()

    private fun assertBearerAuth(operation: JsonNode) {
        assertTrue(operation.path("security").any { it.has("bearerAuth") })
    }

    private fun assertErrorSchemaReference(response: JsonNode) {
        assertEquals(
            "#/components/schemas/ApiErrorResponse",
            response.path("content").path(MediaType.APPLICATION_JSON_VALUE).path("schema").path("\$ref").asText()
        )
    }

    companion object {
        private val HTTP_METHODS = setOf("get", "post", "put", "patch", "delete", "options", "head", "trace")
    }
}

@ActiveProfiles("test")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK)
@AutoConfigureMockMvc
@Import(OpenApiTestConfig::class)
class OpenApiDisabledPolicyTest(
    @Autowired private val mockMvc: MockMvc
) {
    @Test
    fun `documentation paths are not public when OpenAPI is disabled`() {
        listOf(
            "/v3/api-docs",
            "/v3/api-docs.yaml",
            "/v3/api-docs/swagger-config",
            "/swagger-ui.html",
            "/swagger-ui/index.html"
        ).forEach { path ->
            mockMvc.get(path)
                .andExpect {
                    status { isUnauthorized() }
                    jsonPath("$.code") { value("UNAUTHORIZED") }
                }
        }
    }
}

class OpenApiProfilePolicyTest {
    @Test
    fun `OpenAPI exposure follows the configured profile policy`() {
        assertExposure("local", expected = true)
        assertExposure("test", expected = false)
        assertExposure("integration-test", expected = false)
        assertExposure("prod", expected = false)
        assertExposure("prod", expected = true, overrides = mapOf("APP_OPENAPI_ENABLED" to "true"))
    }

    @Test
    fun `business paths and actuator exclusion use supported springdoc properties`() {
        val resolver = resolver("test")
        assertEquals("/api/**", resolver.getRequiredProperty("springdoc.paths-to-match"))
        assertEquals("false", resolver.getRequiredProperty("springdoc.show-actuator"))
        assertEquals("false", resolver.getRequiredProperty("springdoc.override-with-generic-response"))
    }

    private fun assertExposure(
        profile: String,
        expected: Boolean,
        overrides: Map<String, Any> = emptyMap()
    ) {
        val resolver = resolver(profile, overrides)
        assertEquals(expected.toString(), resolver.getRequiredProperty("app.openapi.enabled"))
        assertEquals(expected.toString(), resolver.getRequiredProperty("springdoc.api-docs.enabled"))
        assertEquals(expected.toString(), resolver.getRequiredProperty("springdoc.swagger-ui.enabled"))
    }

    private fun resolver(profile: String, overrides: Map<String, Any> = emptyMap()): PropertySourcesPropertyResolver {
        val sources = MutablePropertySources().apply {
            addLast(ResourcePropertySource("common", ClassPathResource("application.properties")))
            addFirst(ResourcePropertySource("profile", ClassPathResource("application-$profile.properties")))
            if (overrides.isNotEmpty()) {
                addFirst(MapPropertySource("overrides", overrides))
            }
        }
        return PropertySourcesPropertyResolver(sources)
    }
}

@TestConfiguration
class OpenApiTestConfig {
    @Bean
    fun sqlSessionFactory(): SqlSessionFactory =
        mock(SqlSessionFactory::class.java).apply {
            val configuration = Configuration().apply {
                environment = Environment("test", JdbcTransactionFactory(), mock(DataSource::class.java))
            }
            `when`(this.configuration).thenReturn(configuration)
        }
}
