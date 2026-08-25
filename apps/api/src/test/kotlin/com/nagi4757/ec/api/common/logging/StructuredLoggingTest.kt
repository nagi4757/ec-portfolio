package com.nagi4757.ec.api.common.logging

import ch.qos.logback.classic.Level
import ch.qos.logback.classic.LoggerContext
import ch.qos.logback.classic.spi.LoggingEvent
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test
import org.slf4j.event.KeyValuePair
import org.springframework.boot.logging.logback.StructuredLogEncoder
import org.springframework.core.env.Environment
import org.springframework.core.io.ClassPathResource
import org.springframework.mock.env.MockEnvironment
import java.nio.charset.StandardCharsets
import java.util.Properties

class StructuredLoggingTest {
    @Test
    fun `local profile keeps console logging readable and adds correlation pattern`() {
        val properties = loadProperties("application-local.properties")

        assertThat(properties.getProperty("logging.pattern.correlation"))
            .isEqualTo("[%X{correlationId:-}]")
        assertThat(properties.getProperty("logging.structured.format.console")).isNull()
    }

    @Test
    fun `production profile configures ecs structured console logging`() {
        val properties = loadProperties("application-prod.properties")

        assertThat(properties.getProperty("logging.structured.format.console")).isEqualTo("ecs")
        assertThat(properties.getProperty("logging.structured.ecs.service.environment")).isEqualTo("prod")
    }

    @Test
    fun `spring boot ecs formatter includes mdc and structured key values without sensitive input`() {
        val loggerContext = LoggerContext().apply {
            putObject(
                Environment::class.java.name,
                MockEnvironment()
                    .withProperty("spring.application.name", "api")
                    .withProperty("logging.structured.ecs.service.environment", "prod")
            )
            start()
        }
        val encoder = StructuredLogEncoder().apply {
            context = loggerContext
            setFormat("ecs")
            start()
        }

        try {
            val event = LoggingEvent(
                CorrelationIdFilter::class.java.name,
                loggerContext.getLogger(CorrelationIdFilter::class.java),
                Level.INFO,
                CorrelationIdFilter.COMPLETION_MESSAGE,
                null,
                emptyArray()
            ).apply {
                mdcPropertyMap = mapOf(
                    CorrelationIdContext.MDC_KEY to "21e2a145-37da-47d0-bb27-b5c2a630446a",
                    CorrelationIdFilter.HTTP_METHOD_MDC_KEY to "POST",
                    CorrelationIdFilter.REQUEST_PATH_MDC_KEY to "/api/user/orders"
                )
                addKeyValuePair(KeyValuePair(CorrelationIdFilter.HTTP_STATUS_LOG_KEY, 201))
                addKeyValuePair(KeyValuePair(CorrelationIdFilter.ELAPSED_MS_LOG_KEY, 42L))
            }

            val encoded = String(encoder.encode(event), StandardCharsets.UTF_8)
            val json = jacksonObjectMapper().readTree(encoded)

            assertThat(json.path("message").asText()).isEqualTo(CorrelationIdFilter.COMPLETION_MESSAGE)
            assertThat(json.path(CorrelationIdContext.MDC_KEY).asText())
                .isEqualTo("21e2a145-37da-47d0-bb27-b5c2a630446a")
            assertThat(json.path(CorrelationIdFilter.HTTP_METHOD_MDC_KEY).asText()).isEqualTo("POST")
            assertThat(json.path(CorrelationIdFilter.REQUEST_PATH_MDC_KEY).asText()).isEqualTo("/api/user/orders")
            assertThat(json.path(CorrelationIdFilter.HTTP_STATUS_LOG_KEY).asInt()).isEqualTo(201)
            assertThat(json.path(CorrelationIdFilter.ELAPSED_MS_LOG_KEY).asLong()).isEqualTo(42L)
            assertThat(encoded)
                .doesNotContain("Authorization")
                .doesNotContain("password")
                .doesNotContain("requestBody")
                .doesNotContain("responseBody")
        } finally {
            encoder.stop()
            loggerContext.stop()
        }
    }

    private fun loadProperties(resourceName: String): Properties =
        Properties().apply {
            ClassPathResource(resourceName).inputStream.use(::load)
        }
}
