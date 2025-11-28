package com.nagi4757.ec.api

import org.mybatis.spring.annotation.MapperScan
import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.runApplication

@SpringBootApplication
// 하위 패키지까지 스캔되므로 상위 패키지 하나만 지정해도 됩니다.
@MapperScan(
	basePackages = [
		"com.nagi4757.ec.api.infra.mbg.mapper",   // MBG 생성 Mapper
		//"com.nagi4757.ec.api.product.infra.mapper",   // (있다면) 수동 확장 Mapper
		//"com.nagi4757.ec.api.category.infra.mapper"   // (있다면) 수동 확장 Mapper
	]
)
class ApiApplication

fun main(args: Array<String>) {
	runApplication<ApiApplication>(*args)
}
