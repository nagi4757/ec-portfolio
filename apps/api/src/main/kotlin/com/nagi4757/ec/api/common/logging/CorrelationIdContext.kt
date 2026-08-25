package com.nagi4757.ec.api.common.logging

import jakarta.servlet.http.HttpServletRequest

object CorrelationIdContext {
    const val HEADER_NAME = "X-Correlation-ID"
    const val MDC_KEY = "correlationId"
    const val REQUEST_ATTRIBUTE = "correlationId"

    fun get(request: HttpServletRequest): String =
        requireNotNull(request.getAttribute(REQUEST_ATTRIBUTE) as? String) {
            "Correlation ID is not available for the current request"
        }
}
