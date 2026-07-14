package com.nagi4757.ec.api.auth.domain.model

import java.time.Instant

data class User(
    val id: Long? = null,
    val email: String,
    val passwordHash: String,
    val name: String,
    val role: UserRole,
    val createdAt: Instant? = null
)

