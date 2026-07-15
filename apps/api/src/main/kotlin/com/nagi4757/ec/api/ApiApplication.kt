package com.nagi4757.ec.api

import org.apache.ibatis.annotations.Mapper
import org.mybatis.spring.annotation.MapperScan
import org.mybatis.spring.annotation.MapperScans
import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.runApplication

@SpringBootApplication
@MapperScans(
	value = [
		MapperScan(basePackages = ["com.nagi4757.ec.api.infra.mbg.mapper"]), // MBG 생성 Mapper
		MapperScan(
			basePackages = ["com.nagi4757.ec.api"],
			annotationClass = Mapper::class // 수동 Mapper(@Mapper) 자동 스캔
		)
	]
)
class ApiApplication

fun main(args: Array<String>) {
	runApplication<ApiApplication>(*args)
}
