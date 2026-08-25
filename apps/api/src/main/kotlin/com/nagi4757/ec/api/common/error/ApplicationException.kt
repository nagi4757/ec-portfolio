package com.nagi4757.ec.api.common.error

open class ApplicationException(
    val errorCode: ApiErrorCode,
    message: String = errorCode.defaultMessage
) : RuntimeException(message)

class ResourceNotFoundException(
    errorCode: ApiErrorCode
) : ApplicationException(errorCode)

class EmptyCartException : ApplicationException(ApiErrorCode.EMPTY_CART)

class InvalidCartQuantityException : ApplicationException(ApiErrorCode.INVALID_CART_QUANTITY)

class InsufficientStockException : ApplicationException(ApiErrorCode.INSUFFICIENT_STOCK)

class InvalidOrderStatusException : ApplicationException(ApiErrorCode.INVALID_ORDER_STATUS)

class EmailAlreadyExistsException : ApplicationException(ApiErrorCode.EMAIL_ALREADY_EXISTS)

class InvalidCredentialsException : ApplicationException(ApiErrorCode.INVALID_CREDENTIALS)

class UserCreationFailedException : ApplicationException(ApiErrorCode.USER_CREATION_FAILED)
