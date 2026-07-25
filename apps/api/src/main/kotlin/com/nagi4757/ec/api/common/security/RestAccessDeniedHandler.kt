package com.nagi4757.ec.api.common.security

import com.nagi4757.ec.api.common.error.ApiErrorCode
import jakarta.servlet.http.HttpServletRequest
import jakarta.servlet.http.HttpServletResponse
import org.springframework.security.access.AccessDeniedException
import org.springframework.security.web.access.AccessDeniedHandler
import org.springframework.stereotype.Component

@Component
class RestAccessDeniedHandler(
    private val errorResponseWriter: SecurityErrorResponseWriter
) : AccessDeniedHandler {
    override fun handle(
        request: HttpServletRequest,
        response: HttpServletResponse,
        accessDeniedException: AccessDeniedException
    ) {
        errorResponseWriter.write(request, response, ApiErrorCode.ACCESS_DENIED)
    }
}
