package com.nagi4757.ec.api.category.application

import com.nagi4757.ec.api.category.application.command.CreateCategoryCommand
import com.nagi4757.ec.api.category.application.command.UpdateCategoryCommand
import com.nagi4757.ec.api.category.domain.model.Category
import com.nagi4757.ec.api.category.domain.repository.CategoryRepository
import com.nagi4757.ec.api.common.error.ApiErrorCode
import com.nagi4757.ec.api.common.error.ResourceNotFoundException
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional

@Service
class CategoryService(
	private val categoryRepository: CategoryRepository
) {
	@Transactional(readOnly = true)
	fun get(id: Long): Category? = categoryRepository.findById(id)

	@Transactional(readOnly = true)
	fun listAll(): List<Category> = categoryRepository.findAll()

	@Transactional
	fun create(cmd: CreateCategoryCommand): Category {
		val category = Category(
			id = null,
			name = cmd.name,
			description = cmd.description
		)
		val newId = categoryRepository.create(category)
		return getRequired(newId)
	}

	@Transactional
	fun update(id: Long, cmd: UpdateCategoryCommand): Category {
		val current = categoryRepository.findById(id)
			?: throw ResourceNotFoundException(ApiErrorCode.CATEGORY_NOT_FOUND)
		val updated = current.copy(
			name = cmd.name ?: current.name,
			description = cmd.description ?: current.description
		)
		categoryRepository.update(updated)
		return getRequired(id)
	}

	@Transactional
	fun delete(id: Long) {
		if (categoryRepository.findById(id) == null) {
			throw ResourceNotFoundException(ApiErrorCode.CATEGORY_NOT_FOUND)
		}
		categoryRepository.delete(id)
	}

	private fun getRequired(id: Long): Category =
		categoryRepository.findById(id)
			?: throw ResourceNotFoundException(ApiErrorCode.CATEGORY_NOT_FOUND)
}
