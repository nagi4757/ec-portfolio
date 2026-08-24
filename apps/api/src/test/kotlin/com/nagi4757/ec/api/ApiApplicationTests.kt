package com.nagi4757.ec.api

import org.junit.jupiter.api.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import org.apache.ibatis.session.Configuration
import org.apache.ibatis.session.SqlSessionFactory
import org.apache.ibatis.mapping.Environment
import org.apache.ibatis.transaction.jdbc.JdbcTransactionFactory
import javax.sql.DataSource
import org.springframework.boot.test.context.TestConfiguration
import org.springframework.context.annotation.Bean
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.test.context.ActiveProfiles

@ActiveProfiles("test")
@SpringBootTest
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
