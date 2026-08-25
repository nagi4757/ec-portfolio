package com.nagi4757.ec.api.common.logging

import jakarta.servlet.FilterChain
import jakarta.servlet.http.HttpServletRequest
import jakarta.servlet.http.HttpServletResponse
import org.slf4j.LoggerFactory
import org.slf4j.MDC
import org.springframework.core.Ordered
import org.springframework.core.annotation.Order
import org.springframework.stereotype.Component
import org.springframework.web.filter.OncePerRequestFilter
import java.util.Collections
import java.util.UUID
import java.util.concurrent.TimeUnit

@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
class CorrelationIdFilter : OncePerRequestFilter() {
    private val logger = LoggerFactory.getLogger(javaClass)

    override fun doFilterInternal(
        request: HttpServletRequest,
        response: HttpServletResponse,
        filterChain: FilterChain
    ) {
        val correlationId = resolveCorrelationId(request)
        val requestPath = request.requestURI
        val startedAt = System.nanoTime()
        var chainCompleted = false

        request.setAttribute(CorrelationIdContext.REQUEST_ATTRIBUTE, correlationId)
        response.setHeader(CorrelationIdContext.HEADER_NAME, correlationId)
        MDC.put(CorrelationIdContext.MDC_KEY, correlationId)
        MDC.put(HTTP_METHOD_MDC_KEY, request.method)
        MDC.put(REQUEST_PATH_MDC_KEY, requestPath)

        try {
            filterChain.doFilter(request, response)
            chainCompleted = true
        } finally {
            val status = if (chainCompleted) {
                response.status
            } else {
                maxOf(response.status, HttpServletResponse.SC_INTERNAL_SERVER_ERROR)
            }
            val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt)

            try {
                if (!isSuccessfulHealthProbe(requestPath, status)) {
                    logRequestCompletion(status, elapsedMs)
                }
            } finally {
                MDC.remove(REQUEST_PATH_MDC_KEY)
                MDC.remove(HTTP_METHOD_MDC_KEY)
                MDC.remove(CorrelationIdContext.MDC_KEY)
            }
        }
    }

    private fun resolveCorrelationId(request: HttpServletRequest): String {
        val headerValues = Collections.list(request.getHeaders(CorrelationIdContext.HEADER_NAME))
        if (headerValues.size != 1) {
            return newCorrelationId()
        }

        val value = headerValues.single()
        if (value.length != UUID_STRING_LENGTH) {
            return newCorrelationId()
        }

        val parsed = runCatching { UUID.fromString(value) }.getOrNull()
            ?: return newCorrelationId()
        val canonical = parsed.toString()

        return if (canonical.equals(value, ignoreCase = true)) canonical else newCorrelationId()
    }

    private fun logRequestCompletion(status: Int, elapsedMs: Long) {
        val loggingEvent = if (status >= HttpServletResponse.SC_INTERNAL_SERVER_ERROR) {
            logger.atWarn()
        } else {
            logger.atInfo()
        }
        loggingEvent
            .addKeyValue(HTTP_STATUS_LOG_KEY, status)
            .addKeyValue(ELAPSED_MS_LOG_KEY, elapsedMs)
            .log(COMPLETION_MESSAGE)
    }

    private fun isSuccessfulHealthProbe(path: String, status: Int): Boolean =
        status in 200..299 && path in HEALTH_PATHS

    private fun newCorrelationId(): String = UUID.randomUUID().toString()

    companion object {
        const val HTTP_METHOD_MDC_KEY = "httpMethod"
        const val REQUEST_PATH_MDC_KEY = "requestPath"
        const val HTTP_STATUS_LOG_KEY = "httpStatus"
        const val ELAPSED_MS_LOG_KEY = "elapsedMs"
        const val COMPLETION_MESSAGE = "HTTP request completed"

        private const val UUID_STRING_LENGTH = 36
        private val HEALTH_PATHS = setOf(
            "/actuator/health",
            "/actuator/health/liveness",
            "/actuator/health/readiness"
        )
    }
}
