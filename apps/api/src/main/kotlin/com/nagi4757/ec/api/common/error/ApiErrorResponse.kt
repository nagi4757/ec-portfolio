package com.nagi4757.ec.api.common.error

import java.time.Instant

data class ApiErrorResponse(
    val timestamp: Instant,
    val status: Int,
    val code: String,
    val message: String,
    val path: String,
    val fieldErrors: List<ApiFieldError> = emptyList()
) {
    companion object {
        fun of(
            errorCode: ApiErrorCode,
            path: String,
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
                fieldErrors = fieldErrors
            )
    }
}

data class ApiFieldError(
    val field: String,
    val code: String,
    val message: String
)
