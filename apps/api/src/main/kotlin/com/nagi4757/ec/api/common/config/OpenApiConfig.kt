package com.nagi4757.ec.api.common.config

import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ApiErrorResponse
import com.nagi4757.ec.api.common.error.ApiFieldError
import com.nagi4757.ec.api.common.logging.CorrelationIdContext
import io.swagger.v3.core.converter.ModelConverters
import io.swagger.v3.oas.models.Components
import io.swagger.v3.oas.models.OpenAPI
import io.swagger.v3.oas.models.SpecVersion
import io.swagger.v3.oas.models.headers.Header
import io.swagger.v3.oas.models.info.Info
import io.swagger.v3.oas.models.media.Content
import io.swagger.v3.oas.models.media.ComposedSchema
import io.swagger.v3.oas.models.media.JsonSchema
import io.swagger.v3.oas.models.media.MediaType
import io.swagger.v3.oas.models.media.Schema
import io.swagger.v3.oas.models.media.StringSchema
import io.swagger.v3.oas.models.parameters.HeaderParameter
import io.swagger.v3.oas.models.responses.ApiResponse
import io.swagger.v3.oas.models.responses.ApiResponses
import io.swagger.v3.oas.models.security.SecurityScheme
import io.swagger.v3.oas.models.tags.Tag
import org.springdoc.core.customizers.OpenApiCustomizer
import org.springdoc.core.customizers.OperationCustomizer
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration

@Configuration
class OpenApiConfig {
    @Bean
    fun ecPortfolioOpenApi(): OpenAPI = OpenAPI()
        .info(
            Info()
                .title("EC Portfolio API")
                .version("1.0")
                .description(
                    """
                    EC portfolio business API.

                    Protected endpoints use JWT bearer authentication. Unexpected server errors use
                    the common ApiErrorResponse with the INTERNAL_SERVER_ERROR code.
                    """.trimIndent()
                )
        )
        .tags(
            listOf(
                Tag().name("Public - Auth").description("Public authentication APIs."),
                Tag().name("Public - Categories").description("Public category APIs."),
                Tag().name("Public - Products").description("Public product APIs."),
                Tag().name("User - Auth").description("Authenticated user APIs."),
                Tag().name("User - Cart").description("Authenticated user cart APIs."),
                Tag().name("User - Orders").description("Authenticated user order APIs."),
                Tag().name("Admin - Categories").description("Category administration APIs. ADMIN role is required."),
                Tag().name("Admin - Products").description("Product administration APIs. ADMIN role is required."),
                Tag().name("Admin - Orders").description("Order administration APIs. ADMIN role is required.")
            )
        )
        .components(apiComponents())

    private fun apiComponents(): Components = Components().apply {
        ModelConverters.getInstance()
            .read(ApiErrorResponse::class.java)
            .forEach(::addSchemas)
        ModelConverters.getInstance()
            .read(ApiFieldError::class.java)
            .forEach(::addSchemas)

        addSecuritySchemes(
            BEARER_AUTH_NAME,
            SecurityScheme()
                .type(SecurityScheme.Type.HTTP)
                .scheme("bearer")
                .bearerFormat("JWT")
                .description("JWT access token returned by the login API.")
        )
        addParameters(
            CORRELATION_ID_PARAMETER_NAME,
            HeaderParameter()
                .name(CorrelationIdContext.HEADER_NAME)
                .required(false)
                .description(
                    "Optional request correlation ID in UUID format. " +
                        "The server replaces an invalid value with a newly generated UUID."
                )
                .schema(StringSchema().format("uuid"))
        )
        addHeaders(
            CORRELATION_ID_HEADER_NAME,
            Header()
                .description("Correlation ID assigned to the request.")
                .schema(StringSchema().format("uuid"))
        )
    }

    @Bean
    fun apiErrorResponseCustomizer(): OperationCustomizer = OperationCustomizer { operation, handlerMethod ->
        val classErrorCodes = handlerMethod.beanType
            .getAnnotation(ApiErrorCodes::class.java)
            ?.value
            ?.toList()
            .orEmpty()
        val methodErrorCodes = handlerMethod
            .getMethodAnnotation(ApiErrorCodes::class.java)
            ?.value
            ?.toList()
            .orEmpty()

        (classErrorCodes + methodErrorCodes)
            .distinct()
            .groupBy { it.status.value().toString() }
            .forEach { (responseCode, errorCodes) ->
                val responses = operation.responses ?: ApiResponses().also { operation.responses = it }
                responses.addApiResponse(responseCode, errorResponse(errorCodes))
            }

        operation
    }

    private fun errorResponse(errorCodes: List<ApiErrorCode>): ApiResponse =
        ApiResponse()
            .description(errorCodes.joinToString(" or ") { it.name })
            .content(
                Content().addMediaType(
                    org.springframework.http.MediaType.APPLICATION_JSON_VALUE,
                    MediaType().schema(
                        Schema<Any>().`$ref`(API_ERROR_RESPONSE_SCHEMA_REF)
                    )
                )
            )

    @Bean
    fun correlationIdOpenApiCustomizer(): OpenApiCustomizer = OpenApiCustomizer { openApi ->
        openApi.paths?.values?.forEach { pathItem ->
            pathItem.readOperations().forEach { operation ->
                val hasCorrelationId = operation.parameters.orEmpty().any {
                    it.name == CorrelationIdContext.HEADER_NAME || it.`$ref` == CORRELATION_ID_PARAMETER_REF
                }
                if (!hasCorrelationId) {
                    operation.addParametersItem(
                        HeaderParameter().`$ref`(CORRELATION_ID_PARAMETER_REF)
                    )
                }

                operation.responses?.values?.forEach(::addCorrelationIdHeader)
            }
        }

        val errorSchema = openApi.components?.schemas?.get("ApiErrorResponse")
        errorSchema?.properties?.get("code")?.apply {
            ApiErrorCode.entries.forEach { addEnumItemObject(it.name) }
        }
        errorSchema?.properties?.get("correlationId")?.apply {
            format = "uuid"
            description = "Correlation ID matching the X-Correlation-ID response header."
        }
    }

    @Bean
    fun nullableShippingAddressOpenApiCustomizer(): OpenApiCustomizer = OpenApiCustomizer { openApi ->
        val orderResponse = openApi.components?.schemas?.get("OrderResponse") ?: return@OpenApiCustomizer
        val currentProperty = orderResponse.properties?.get("shippingAddress") ?: return@OpenApiCustomizer
        val shippingAddressReference = currentProperty.`$ref` ?: return@OpenApiCustomizer

        orderResponse.properties["shippingAddress"] = ComposedSchema().apply {
            specVersion = SpecVersion.V31
            description = currentProperty.description
            oneOf = listOf(
                JsonSchema().apply {
                    specVersion = SpecVersion.V31
                    `$ref` = shippingAddressReference
                },
                JsonSchema().apply {
                    specVersion = SpecVersion.V31
                    types = linkedSetOf("null")
                }
            )
        }
    }

    private fun addCorrelationIdHeader(response: ApiResponse) {
        if (!response.headers.orEmpty().containsKey(CorrelationIdContext.HEADER_NAME)) {
            response.addHeaderObject(
                CorrelationIdContext.HEADER_NAME,
                Header().`$ref`(CORRELATION_ID_HEADER_REF)
            )
        }
    }

    companion object {
        const val BEARER_AUTH_NAME = "bearerAuth"

        private const val CORRELATION_ID_PARAMETER_NAME = "CorrelationId"
        private const val CORRELATION_ID_HEADER_NAME = "CorrelationId"
        private const val API_ERROR_RESPONSE_SCHEMA_REF = "#/components/schemas/ApiErrorResponse"
        private const val CORRELATION_ID_PARAMETER_REF = "#/components/parameters/$CORRELATION_ID_PARAMETER_NAME"
        private const val CORRELATION_ID_HEADER_REF = "#/components/headers/$CORRELATION_ID_HEADER_NAME"
    }
}
