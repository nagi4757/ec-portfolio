package com.nagi4757.ec.api.auth.application.command

data class LoginCommand(
    val email: String,
    val password: String
)

