package com.nagi4757.ec.api.common.error

import com.nagi4757.ec.api.common.logging.CorrelationIdContext
import jakarta.servlet.http.HttpServletRequest
import org.slf4j.LoggerFactory
import org.springframework.http.HttpStatusCode
import org.springframework.http.ResponseEntity
import org.springframework.http.converter.HttpMessageNotReadableException
import org.springframework.web.bind.MethodArgumentNotValidException
import org.springframework.web.bind.MissingServletRequestParameterException
import org.springframework.web.bind.annotation.ExceptionHandler
import org.springframework.web.bind.annotation.RestControllerAdvice
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException
import org.springframework.web.server.ResponseStatusException
import org.springframework.web.servlet.resource.NoResourceFoundException

@RestControllerAdvice
class GlobalExceptionHandler {
    private val logger = LoggerFactory.getLogger(javaClass)

    @ExceptionHandler(ApplicationException::class)
    fun handleApplicationException(
        exception: ApplicationException,
        request: HttpServletRequest
    ): ResponseEntity<ApiErrorResponse> =
        response(
            request = request,
            errorCode = exception.errorCode,
            message = exception.message ?: exception.errorCode.defaultMessage
        )

    @ExceptionHandler(ResponseStatusException::class)
    fun handleResponseStatusException(
        exception: ResponseStatusException,
        request: HttpServletRequest
    ): ResponseEntity<ApiErrorResponse> {
        val errorCode = when (exception.statusCode.value()) {
            400 -> ApiErrorCode.BAD_REQUEST
            401 -> ApiErrorCode.UNAUTHORIZED
            403 -> ApiErrorCode.ACCESS_DENIED
            404 -> ApiErrorCode.RESOURCE_NOT_FOUND
            409 -> ApiErrorCode.CONFLICT
            else -> {
                if (exception.statusCode.is4xxClientError) {
                    ApiErrorCode.BAD_REQUEST
                } else {
                    ApiErrorCode.INTERNAL_SERVER_ERROR
                }
            }
        }

        return response(
            request = request,
            errorCode = errorCode,
            status = exception.statusCode
        )
    }

    @ExceptionHandler(MethodArgumentNotValidException::class)
    fun handleValidationException(
        exception: MethodArgumentNotValidException,
        request: HttpServletRequest
    ): ResponseEntity<ApiErrorResponse> {
        val fieldErrors = exception.bindingResult.fieldErrors.map {
            ApiFieldError(
                field = it.field,
                code = it.code ?: "Invalid",
                message = it.defaultMessage ?: "Invalid value"
            )
        }

        return response(
            request = request,
            errorCode = ApiErrorCode.VALIDATION_FAILED,
            fieldErrors = fieldErrors
        )
    }

    @ExceptionHandler(HttpMessageNotReadableException::class)
    fun handleMalformedRequest(
        exception: HttpMessageNotReadableException,
        request: HttpServletRequest
    ): ResponseEntity<ApiErrorResponse> =
        response(request, ApiErrorCode.MALFORMED_REQUEST)

    @ExceptionHandler(
        MissingServletRequestParameterException::class,
        MethodArgumentTypeMismatchException::class
    )
    fun handleBadRequest(
        exception: Exception,
        request: HttpServletRequest
    ): ResponseEntity<ApiErrorResponse> =
        response(request, ApiErrorCode.BAD_REQUEST)

    @ExceptionHandler(NoResourceFoundException::class)
    fun handleNoResourceFound(request: HttpServletRequest): ResponseEntity<ApiErrorResponse> =
        response(request, ApiErrorCode.RESOURCE_NOT_FOUND)

    @ExceptionHandler(Exception::class)
    fun handleUnexpectedException(
        exception: Exception,
        request: HttpServletRequest
    ): ResponseEntity<ApiErrorResponse> {
        logger.error("Unexpected exception", exception)
        return response(request, ApiErrorCode.INTERNAL_SERVER_ERROR)
    }

    private fun response(
        request: HttpServletRequest,
        errorCode: ApiErrorCode,
        message: String = errorCode.defaultMessage,
        fieldErrors: List<ApiFieldError> = emptyList(),
        status: HttpStatusCode = errorCode.status
    ): ResponseEntity<ApiErrorResponse> =
        ResponseEntity
            .status(status)
            .body(
                ApiErrorResponse.of(
                    errorCode = errorCode,
                    path = request.requestURI,
                    correlationId = CorrelationIdContext.get(request),
                    message = message,
                    fieldErrors = fieldErrors,
                    status = status.value()
                )
            )
}
