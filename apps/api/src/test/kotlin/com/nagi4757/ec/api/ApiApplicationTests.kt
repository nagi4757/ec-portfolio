package com.nagi4757.ec.api

import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import org.apache.ibatis.session.Configuration
import org.apache.ibatis.session.SqlSessionFactory
import org.apache.ibatis.mapping.Environment
import org.apache.ibatis.transaction.jdbc.JdbcTransactionFactory
import javax.sql.DataSource
import org.mybatis.spring.annotation.MapperScan
import org.springframework.boot.test.context.TestConfiguration
import org.springframework.context.annotation.Bean
import org.springframework.boot.test.context.SpringBootTest

@SpringBootTest(
	properties = [
		"spring.autoconfigure.exclude=" +
				"org.springframework.boot.autoconfigure.jdbc.DataSourceAutoConfiguration",
		"spring.flyway.enabled=false", // flyway 의존성 있을 때 안전장치
		"spring.main.lazy-initialization=true"
	]
)
@MapperScan("com.nagi4757.ec.api.infra.mbg.mapper")
class ApiApplicationTests {
	@Test fun contextLoads() {}

	@TestConfiguration
	class TestMybatisConfig {
		@Bean
		fun sqlSessionFactory(): SqlSessionFactory =
			mock(SqlSessionFactory::class.java).apply {
				val cfg = Configuration().apply {
					environment = Environment("test", JdbcTransactionFactory(), mock(DataSource::class.java))
				}
				`when`(configuration).thenReturn(cfg)
			}
	}
}
