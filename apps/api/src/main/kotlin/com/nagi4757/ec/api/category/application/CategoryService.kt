package com.nagi4757.ec.api.category.application

import com.nagi4757.ec.api.category.application.command.CreateCategoryCommand
import com.nagi4757.ec.api.category.application.command.UpdateCategoryCommand
import com.nagi4757.ec.api.category.domain.model.Category
import com.nagi4757.ec.api.category.domain.repository.CategoryRepository
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
		return categoryRepository.findById(newId)!!
	}

	@Transactional
	fun update(id: Long, cmd: UpdateCategoryCommand): Category {
		val current = categoryRepository.findById(id) ?: error("Category($id) not found")
		val updated = current.copy(
			name = cmd.name ?: current.name,
			description = cmd.description ?: current.description
		)
		categoryRepository.update(updated)
		return categoryRepository.findById(id)!!
	}

	@Transactional
	fun delete(id: Long) {
		get(id)
		categoryRepository.delete(id)
	}
}