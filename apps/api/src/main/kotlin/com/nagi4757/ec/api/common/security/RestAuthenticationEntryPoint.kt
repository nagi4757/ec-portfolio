package com.nagi4757.ec.api.common.security

import com.nagi4757.ec.api.common.error.ApiErrorCode
import jakarta.servlet.http.HttpServletRequest
import jakarta.servlet.http.HttpServletResponse
import org.springframework.security.core.AuthenticationException
import org.springframework.security.web.AuthenticationEntryPoint
import org.springframework.stereotype.Component

@Component
class RestAuthenticationEntryPoint(
    private val errorResponseWriter: SecurityErrorResponseWriter
) : AuthenticationEntryPoint {
    override fun commence(
        request: HttpServletRequest,
        response: HttpServletResponse,
        authException: AuthenticationException
    ) {
        errorResponseWriter.write(request, response, ApiErrorCode.UNAUTHORIZED)
    }
}
