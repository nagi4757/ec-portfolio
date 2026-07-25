package com.nagi4757.ec.api.common.security

import com.fasterxml.jackson.databind.ObjectMapper
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ApiErrorResponse
import jakarta.servlet.http.HttpServletRequest
import jakarta.servlet.http.HttpServletResponse
import org.springframework.http.MediaType
import org.springframework.stereotype.Component

@Component
class SecurityErrorResponseWriter(
    private val objectMapper: ObjectMapper
) {
    fun write(
        request: HttpServletRequest,
        response: HttpServletResponse,
        errorCode: ApiErrorCode
    ) {
        response.status = errorCode.status.value()
        response.contentType = MediaType.APPLICATION_JSON_VALUE
        response.characterEncoding = Charsets.UTF_8.name()
        objectMapper.writeValue(
            response.outputStream,
            ApiErrorResponse.of(errorCode, request.requestURI)
        )
    }
}
