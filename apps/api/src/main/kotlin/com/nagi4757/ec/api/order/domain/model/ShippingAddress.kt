package com.nagi4757.ec.api.order.domain.model

data class ShippingAddress(
    val recipientName: String,
    val postalCode: String,
    val prefecture: String,
    val city: String,
    val addressLine1: String,
    val addressLine2: String?,
    val phoneNumber: String
)
