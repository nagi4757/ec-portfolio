package com.nagi4757.ec.api.auth.application.command

data class SignUpCommand(
    val email: String,
    val password: String,
    val name: String
)

