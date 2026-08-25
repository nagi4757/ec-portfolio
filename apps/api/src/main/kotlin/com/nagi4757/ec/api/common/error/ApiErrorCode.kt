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
    USER_NOT_FOUND(HttpStatus.NOT_FOUND, "User was not found"),
    ORDER_NOT_FOUND(HttpStatus.NOT_FOUND, "Order was not found"),
    EMPTY_CART(HttpStatus.BAD_REQUEST, "Cart is empty"),
    INVALID_CART_QUANTITY(HttpStatus.BAD_REQUEST, "Cart quantity is invalid"),
    INSUFFICIENT_STOCK(HttpStatus.CONFLICT, "Product stock is insufficient"),
    INVALID_ORDER_STATUS(HttpStatus.BAD_REQUEST, "Order status is invalid"),
    EMAIL_ALREADY_EXISTS(HttpStatus.CONFLICT, "Email already exists"),
    INVALID_CREDENTIALS(HttpStatus.UNAUTHORIZED, "Invalid credentials"),
    USER_CREATION_FAILED(HttpStatus.INTERNAL_SERVER_ERROR, "User creation failed"),
    RESOURCE_NOT_FOUND(HttpStatus.NOT_FOUND, "Resource was not found"),
    CONFLICT(HttpStatus.CONFLICT, "Request conflicts with the current resource state"),
    INTERNAL_SERVER_ERROR(HttpStatus.INTERNAL_SERVER_ERROR, "An unexpected error occurred")
}
