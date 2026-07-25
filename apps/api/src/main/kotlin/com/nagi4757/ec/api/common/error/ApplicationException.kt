package com.nagi4757.ec.api.common.error

open class ApplicationException(
    val errorCode: ApiErrorCode,
    message: String = errorCode.defaultMessage
) : RuntimeException(message)

class ResourceNotFoundException(
    errorCode: ApiErrorCode
) : ApplicationException(errorCode)
