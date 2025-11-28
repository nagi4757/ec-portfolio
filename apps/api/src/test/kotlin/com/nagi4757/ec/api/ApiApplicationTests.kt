package com.nagi4757.ec.api

import org.junit.jupiter.api.Test
import org.mybatis.spring.annotation.MapperScan
import org.springframework.boot.test.context.SpringBootTest

@SpringBootTest(
	properties = [
		"spring.autoconfigure.exclude=" +
				"org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration",
		"spring.flyway.enabled=false" // flyway 의존성 있을 때 안전장치
	]
)
@MapperScan("com.nagi4757.ec.api") // 패키지에 맞게
class ApiApplicationTests {
	@Test fun contextLoads() {}
}
