package com.nagi4757.ec.api.common.config

import com.nagi4757.ec.api.common.error.ApiErrorCode

@Target(AnnotationTarget.CLASS, AnnotationTarget.FUNCTION)
@Retention(AnnotationRetention.RUNTIME)
annotation class ApiErrorCodes(vararg val value: ApiErrorCode)
