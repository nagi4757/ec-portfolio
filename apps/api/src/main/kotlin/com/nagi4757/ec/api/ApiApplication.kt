package com.nagi4757.ec.api

import org.apache.ibatis.annotations.Mapper
import org.mybatis.spring.annotation.MapperScan
import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.autoconfigure.security.servlet.UserDetailsServiceAutoConfiguration
import org.springframework.boot.runApplication

@SpringBootApplication(exclude = [UserDetailsServiceAutoConfiguration::class])
@MapperScan(
    basePackages = ["com.nagi4757.ec.api"],
    annotationClass = Mapper::class
)
class ApiApplication

fun main(args: Array<String>) {
	runApplication<ApiApplication>(*args)
}
