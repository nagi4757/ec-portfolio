package com.nagi4757.ec.api.auth.application.dto

import com.nagi4757.ec.api.auth.domain.model.User

data class AuthResult(
    val accessToken: String,
    val user: User
)

