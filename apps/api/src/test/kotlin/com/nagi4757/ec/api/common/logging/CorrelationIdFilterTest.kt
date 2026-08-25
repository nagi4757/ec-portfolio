package com.nagi4757.ec.api.common.logging

import ch.qos.logback.classic.Logger
import ch.qos.logback.classic.spi.ILoggingEvent
import ch.qos.logback.core.read.ListAppender
import jakarta.servlet.FilterChain
import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows
import org.slf4j.LoggerFactory
import org.slf4j.MDC
import org.springframework.mock.web.MockHttpServletRequest
import org.springframework.mock.web.MockHttpServletResponse
import java.util.UUID

class CorrelationIdFilterTest {
    private lateinit var filter: CorrelationIdFilter
    private lateinit var filterLogger: Logger
    private lateinit var appender: ListAppender<ILoggingEvent>

    @BeforeEach
    fun setUp() {
        filter = CorrelationIdFilter()
        filterLogger = LoggerFactory.getLogger(CorrelationIdFilter::class.java) as Logger
        appender = object : ListAppender<ILoggingEvent>() {
            override fun append(eventObject: ILoggingEvent) {
                eventObject.prepareForDeferredProcessing()
                super.append(eventObject)
            }
        }.apply { start() }
        filterLogger.addAppender(appender)
        removeOwnedMdcValues()
    }

    @AfterEach
    fun tearDown() {
        filterLogger.detachAppender(appender)
        appender.stop()
        removeOwnedMdcValues()
    }

    @Test
    fun `missing header creates correlation id and exposes it throughout request`() {
        val request = MockHttpServletRequest("GET", "/api/public/products")
        val response = MockHttpServletResponse()

        filter.doFilter(request, response, FilterChain { _, _ ->
            val correlationId = MDC.get(CorrelationIdContext.MDC_KEY)
            assertThat(correlationId).isEqualTo(request.getAttribute(CorrelationIdContext.REQUEST_ATTRIBUTE))
            assertThat(UUID.fromString(correlationId).toString()).isEqualTo(correlationId)
            assertThat(MDC.get(CorrelationIdFilter.HTTP_METHOD_MDC_KEY)).isEqualTo("GET")
            assertThat(MDC.get(CorrelationIdFilter.REQUEST_PATH_MDC_KEY)).isEqualTo("/api/public/products")
        })

        val correlationId = response.getHeader(CorrelationIdContext.HEADER_NAME)
        assertThat(UUID.fromString(correlationId).toString()).isEqualTo(correlationId)
        assertThat(completionEvent().mdcPropertyMap[CorrelationIdContext.MDC_KEY]).isEqualTo(correlationId)
    }

    @Test
    fun `valid header is reused and uppercase uuid is normalized`() {
        val canonical = UUID.randomUUID().toString()
        val request = MockHttpServletRequest("GET", "/api/public/products").apply {
            addHeader(CorrelationIdContext.HEADER_NAME, canonical.uppercase())
        }
        val response = MockHttpServletResponse()

        filter.doFilter(request, response, FilterChain { _, _ ->
            assertThat(MDC.get(CorrelationIdContext.MDC_KEY)).isEqualTo(canonical)
        })

        assertThat(response.getHeader(CorrelationIdContext.HEADER_NAME)).isEqualTo(canonical)
    }

    @Test
    fun `invalid empty long and line break headers are replaced`() {
        val invalidValues = listOf(
            "",
            "not-a-uuid",
            "x".repeat(37),
            "bad\r\nvalue"
        )

        invalidValues.forEach { invalidValue ->
            val request = MockHttpServletRequest("GET", "/api/public/products").apply {
                addHeader(CorrelationIdContext.HEADER_NAME, invalidValue)
            }
            val response = MockHttpServletResponse()

            filter.doFilter(request, response, FilterChain { _, _ -> })

            val generated = response.getHeader(CorrelationIdContext.HEADER_NAME)
            assertThat(UUID.fromString(generated).toString()).isEqualTo(generated)
            assertThat(generated).isNotEqualTo(invalidValue)
        }
    }

    @Test
    fun `multiple correlation headers are replaced`() {
        val first = UUID.randomUUID().toString()
        val second = UUID.randomUUID().toString()
        val request = MockHttpServletRequest("GET", "/api/public/products").apply {
            addHeader(CorrelationIdContext.HEADER_NAME, first)
            addHeader(CorrelationIdContext.HEADER_NAME, second)
        }
        val response = MockHttpServletResponse()

        filter.doFilter(request, response, FilterChain { _, _ -> })

        val generated = response.getHeader(CorrelationIdContext.HEADER_NAME)
        assertThat(UUID.fromString(generated).toString()).isEqualTo(generated)
        assertThat(generated).isNotIn(first, second)
    }

    @Test
    fun `owned mdc values are removed and do not leak to the next request`() {
        val firstResponse = performRequest(MockHttpServletRequest("GET", "/first"))

        assertOwnedMdcValuesAreRemoved()

        val secondResponse = performRequest(MockHttpServletRequest("GET", "/second"))

        assertOwnedMdcValuesAreRemoved()
        assertThat(secondResponse.getHeader(CorrelationIdContext.HEADER_NAME))
            .isNotEqualTo(firstResponse.getHeader(CorrelationIdContext.HEADER_NAME))
    }

    @Test
    fun `cleanup preserves mdc values owned by other components`() {
        MDC.put("unrelatedKey", "preserved")

        try {
            performRequest(MockHttpServletRequest("GET", "/api/public/products"))

            assertOwnedMdcValuesAreRemoved()
            assertThat(MDC.get("unrelatedKey")).isEqualTo("preserved")
        } finally {
            MDC.remove("unrelatedKey")
        }
    }

    @Test
    fun `completion log contains safe request metadata without sensitive input`() {
        val request = MockHttpServletRequest("POST", "/api/public/login").apply {
            queryString = "password=query-secret"
            setContent("{\"password\":\"body-secret\"}".toByteArray())
            addHeader("Authorization", "Bearer jwt-secret")
            addHeader("Cookie", "session=cookie-secret")
        }
        val response = MockHttpServletResponse()

        filter.doFilter(request, response, FilterChain { _, servletResponse ->
            (servletResponse as MockHttpServletResponse).writer.write("response-secret")
        })

        val event = completionEvent()
        assertThat(event.formattedMessage).isEqualTo(CorrelationIdFilter.COMPLETION_MESSAGE)
        assertThat(event.mdcPropertyMap[CorrelationIdFilter.HTTP_METHOD_MDC_KEY]).isEqualTo("POST")
        assertThat(event.mdcPropertyMap[CorrelationIdFilter.REQUEST_PATH_MDC_KEY]).isEqualTo("/api/public/login")
        assertThat(keyValue(event, CorrelationIdFilter.HTTP_STATUS_LOG_KEY)).isEqualTo(200)
        assertThat(keyValue(event, CorrelationIdFilter.ELAPSED_MS_LOG_KEY)).isInstanceOf(Long::class.javaObjectType)

        val loggedContent = buildString {
            append(event.formattedMessage)
            append(event.mdcPropertyMap)
            append(event.keyValuePairs)
        }
        assertThat(loggedContent)
            .doesNotContain("query-secret")
            .doesNotContain("body-secret")
            .doesNotContain("jwt-secret")
            .doesNotContain("cookie-secret")
            .doesNotContain("response-secret")
    }

    @Test
    fun `successful health probe does not write completion log`() {
        val request = MockHttpServletRequest("GET", "/actuator/health/readiness")

        performRequest(request)

        assertThat(appender.list).isEmpty()
    }

    @Test
    fun `unavailable health probe writes completion log`() {
        val request = MockHttpServletRequest("GET", "/actuator/health/readiness")
        val response = MockHttpServletResponse()

        filter.doFilter(request, response, FilterChain { _, servletResponse ->
            (servletResponse as MockHttpServletResponse).status = 503
        })

        assertThat(keyValue(completionEvent(), CorrelationIdFilter.HTTP_STATUS_LOG_KEY)).isEqualTo(503)
    }

    @Test
    fun `unhandled exception is rethrown and completion log records server error`() {
        val request = MockHttpServletRequest("GET", "/api/public/failure")
        val response = MockHttpServletResponse()
        val failure = IllegalStateException("expected failure")

        val thrown = assertThrows<IllegalStateException> {
            filter.doFilter(request, response, FilterChain { _, _ -> throw failure })
        }

        assertThat(thrown).isSameAs(failure)
        assertThat(keyValue(completionEvent(), CorrelationIdFilter.HTTP_STATUS_LOG_KEY)).isEqualTo(500)
        assertOwnedMdcValuesAreRemoved()
    }

    private fun performRequest(request: MockHttpServletRequest): MockHttpServletResponse =
        MockHttpServletResponse().also { response ->
            filter.doFilter(request, response, FilterChain { _, _ -> })
        }

    private fun completionEvent(): ILoggingEvent =
        appender.list.single { it.formattedMessage == CorrelationIdFilter.COMPLETION_MESSAGE }

    private fun keyValue(event: ILoggingEvent, key: String): Any? =
        event.keyValuePairs.single { it.key == key }.value

    private fun assertOwnedMdcValuesAreRemoved() {
        assertThat(MDC.get(CorrelationIdContext.MDC_KEY)).isNull()
        assertThat(MDC.get(CorrelationIdFilter.HTTP_METHOD_MDC_KEY)).isNull()
        assertThat(MDC.get(CorrelationIdFilter.REQUEST_PATH_MDC_KEY)).isNull()
    }

    private fun removeOwnedMdcValues() {
        MDC.remove(CorrelationIdContext.MDC_KEY)
        MDC.remove(CorrelationIdFilter.HTTP_METHOD_MDC_KEY)
        MDC.remove(CorrelationIdFilter.REQUEST_PATH_MDC_KEY)
    }
}
