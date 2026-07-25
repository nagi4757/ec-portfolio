package com.nagi4757.ec.api.common.error

import org.springframework.http.HttpStatus

enum class ApiErrorCode(
    val status: HttpStatus,
    val defaultMessage: String
) {
    VALIDATION_FAILED(HttpStatus.BAD_REQUEST, "Request validation failed"),
    MALFORMED_REQUEST(HttpStatus.BAD_REQUEST, "Malformed request"),
    BAD_REQUEST(HttpStatus.BAD_REQUEST, "Bad request"),
    UNAUTHORIZED(HttpStatus.UNAUTHORIZED, "Authentication is required"),
    ACCESS_DENIED(HttpStatus.FORBIDDEN, "Access is denied"),
    PRODUCT_NOT_FOUND(HttpStatus.NOT_FOUND, "Product was not found"),
    CATEGORY_NOT_FOUND(HttpStatus.NOT_FOUND, "Category was not found"),
    RESOURCE_NOT_FOUND(HttpStatus.NOT_FOUND, "Resource was not found"),
    CONFLICT(HttpStatus.CONFLICT, "Request conflicts with the current resource state"),
    INTERNAL_SERVER_ERROR(HttpStatus.INTERNAL_SERVER_ERROR, "An unexpected error occurred")
}
