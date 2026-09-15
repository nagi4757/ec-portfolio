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

class ProductNotAvailableException : ApplicationException(ApiErrorCode.PRODUCT_NOT_AVAILABLE)

class InvalidOrderStatusException : ApplicationException(ApiErrorCode.INVALID_ORDER_STATUS)

class InvalidOrderTransitionException : ApplicationException(ApiErrorCode.INVALID_ORDER_TRANSITION)

/**
 * A paid order may only leave the system through a refund, which this phase does
 * not implement. Cancelling without one would leave the customer charged for an
 * order that no longer exists, so the request fails closed instead.
 */
class OrderCancellationRequiresRefundException :
    ApplicationException(ApiErrorCode.ORDER_CANCELLATION_REQUIRES_REFUND)

class PaymentDeclinedException : ApplicationException(ApiErrorCode.PAYMENT_DECLINED)

class PaymentFailedException : ApplicationException(ApiErrorCode.PAYMENT_FAILED)

/**
 * The gateway did not tell us whether the charge happened. The order stays
 * reserved so it can be reconciled; it is never silently cancelled.
 */
class PaymentPendingConfirmationException :
    ApplicationException(ApiErrorCode.PAYMENT_PENDING_CONFIRMATION)

/**
 * A different, unsettled payment already exists for this customer. Starting another
 * one could charge them twice, so the second request is refused rather than queued.
 */
class PaymentAttemptInProgressException :
    ApplicationException(ApiErrorCode.PAYMENT_ATTEMPT_IN_PROGRESS)

class PaymentIdempotencyConflictException :
    ApplicationException(ApiErrorCode.PAYMENT_IDEMPOTENCY_CONFLICT)

class EmailAlreadyExistsException : ApplicationException(ApiErrorCode.EMAIL_ALREADY_EXISTS)

class InvalidCredentialsException : ApplicationException(ApiErrorCode.INVALID_CREDENTIALS)

class UserCreationFailedException : ApplicationException(ApiErrorCode.USER_CREATION_FAILED)
