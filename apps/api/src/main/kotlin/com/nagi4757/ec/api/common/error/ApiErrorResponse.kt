package com.nagi4757.ec.api.common.error

import java.time.Instant

data class ApiErrorResponse(
    val timestamp: Instant,
    val status: Int,
    val code: String,
    val message: String,
    val path: String,
    val correlationId: String,
    val fieldErrors: List<ApiFieldError> = emptyList()
) {
    companion object {
        fun of(
            errorCode: ApiErrorCode,
            path: String,
            correlationId: String,
            message: String = errorCode.defaultMessage,
            fieldErrors: List<ApiFieldError> = emptyList(),
            status: Int = errorCode.status.value()
        ): ApiErrorResponse =
            ApiErrorResponse(
                timestamp = Instant.now(),
                status = status,
                code = errorCode.name,
                message = message,
                path = path,
                correlationId = correlationId,
                fieldErrors = fieldErrors
            )
    }
}

data class ApiFieldError(
    val field: String,
    val code: String,
    val message: String
)
