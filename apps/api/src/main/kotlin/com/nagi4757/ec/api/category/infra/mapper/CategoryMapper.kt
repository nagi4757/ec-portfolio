package com.nagi4757.ec.api.category.infra.mapper

import org.apache.ibatis.annotations.Delete
import org.apache.ibatis.annotations.Insert
import org.apache.ibatis.annotations.Mapper
import org.apache.ibatis.annotations.Options
import org.apache.ibatis.annotations.Select
import org.apache.ibatis.annotations.Update

@Mapper
interface CategoryMapper {
    @Select("SELECT id, name, description FROM categories WHERE id = #{id}")
    fun selectById(id: Long): CategoryRecord?

    @Select("SELECT id, name, description FROM categories ORDER BY id DESC")
    fun selectAll(): List<CategoryRecord>

    @Insert("INSERT INTO categories (name, description) VALUES (#{name}, #{description})")
    @Options(useGeneratedKeys = true, keyProperty = "id")
    fun insert(record: CategoryRecord): Int

    @Update("UPDATE categories SET name = #{name}, description = #{description} WHERE id = #{id}")
    fun update(record: CategoryRecord): Int

    @Delete("DELETE FROM categories WHERE id = #{id}")
    fun delete(id: Long): Int
}

data class CategoryRecord(
    var id: Long? = null,
    var name: String? = null,
    var description: String? = null
)
