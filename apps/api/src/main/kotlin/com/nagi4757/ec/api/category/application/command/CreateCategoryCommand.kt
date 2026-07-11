package com.nagi4757.ec.api.category.application.command

data class CreateCategoryCommand(
    val name: String,
    val description: String? = null
)

