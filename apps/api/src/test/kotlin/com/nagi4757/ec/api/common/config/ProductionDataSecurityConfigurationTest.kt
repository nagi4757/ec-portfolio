package com.nagi4757.ec.api.common.config

import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test
import java.util.Properties

class ProductionDataSecurityConfigurationTest {

    @Test
    fun `production database enforces connector identity verification`() {
        val properties = loadProperties("application-prod.properties")
        val jdbcUrl = properties.required("spring.datasource.url")

        assertThat(jdbcUrl).isEqualTo(
            "jdbc:mariadb://\${DB_HOST}:\${DB_PORT}/\${DB_NAME}" +
                "?sslMode=verify-full" +
                "&serverSslCert=/etc/ssl/certs/aws-rds-ap-northeast-1-bundle.pem" +
                "&fallbackToSystemTrustStore=false"
        )
        assertThat(properties.required("spring.datasource.username")).isEqualTo("\${DB_USERNAME}")
        assertThat(properties.required("spring.datasource.password")).isEqualTo("\${DB_PASSWORD}")
        assertThat(jdbcUrl)
            .doesNotContain("\${DB_SSL")
            .doesNotContain("sslMode=trust")
            .doesNotContain("sslMode=required")
            .doesNotContain("sslMode=verify-ca")
            .doesNotContain("trustServerCertificate")
            .doesNotContain("disableSslHostnameVerification")

        val parsed = parseMariaDbConfiguration(
            jdbcUrl
                .replace("\${DB_HOST}", "database.example.com")
                .replace("\${DB_PORT}", "3306")
                .replace("\${DB_NAME}", "ec")
        )
        assertThat(invoke(parsed, "sslMode").toString()).isEqualTo("VERIFY_FULL")
        assertThat(invoke(parsed, "serverSslCert")).isEqualTo(
            "/etc/ssl/certs/aws-rds-ap-northeast-1-bundle.pem"
        )
        assertThat(invoke(parsed, "fallbackToSystemTrustStore")).isEqualTo(false)
    }

    @Test
    fun `production redis enforces TLS and mandatory RBAC credentials`() {
        val properties = loadProperties("application-prod.properties")

        assertThat(properties.required("spring.data.redis.host")).isEqualTo("\${REDIS_HOST}")
        assertThat(properties.required("spring.data.redis.port")).isEqualTo("\${REDIS_PORT}")
        assertThat(properties.required("spring.data.redis.username")).isEqualTo("\${REDIS_USERNAME}")
        assertThat(properties.required("spring.data.redis.password")).isEqualTo("\${REDIS_PASSWORD}")
        assertThat(properties.required("spring.data.redis.ssl.enabled")).isEqualTo("true")
        assertThat(properties.getProperty("spring.data.redis.url")).isNull()
        assertThat(properties.entries.joinToString()).doesNotContain("REDIS_SSL")
    }

    @Test
    fun `non production profiles keep plain infrastructure connections`() {
        val local = loadProperties("application-local.properties")
        val integrationTest = loadProperties("application-integration-test.properties")
        val test = loadProperties("application-test.properties")

        assertThat(local.required("spring.datasource.url"))
            .startsWith("jdbc:mariadb://")
            .doesNotContain("sslMode")
            .doesNotContain("serverSslCert")
        assertThat(local.getProperty("spring.data.redis.ssl.enabled")).isNull()
        assertThat(local.getProperty("spring.data.redis.username")).isNull()
        assertThat(local.getProperty("spring.data.redis.password")).isNull()

        assertThat(integrationTest.getProperty("spring.datasource.url")).isNull()
        assertThat(integrationTest.getProperty("spring.data.redis.ssl.enabled")).isNull()
        assertThat(integrationTest.getProperty("spring.data.redis.username")).isNull()
        assertThat(integrationTest.getProperty("spring.data.redis.password")).isNull()

        assertThat(test.required("spring.autoconfigure.exclude"))
            .contains("DataSourceAutoConfiguration")
        assertThat(test.required("spring.flyway.enabled")).isEqualTo("false")
        assertThat(test.required("management.health.db.enabled")).isEqualTo("false")
        assertThat(test.required("management.health.redis.enabled")).isEqualTo("false")
    }

    private fun loadProperties(resourceName: String): Properties =
        Properties().apply {
            ProductionDataSecurityConfigurationTest::class.java.classLoader
                .getResourceAsStream(resourceName).use { input ->
                requireNotNull(input) { "Missing test resource: $resourceName" }
                load(input)
            }
        }

    private fun Properties.required(key: String): String =
        requireNotNull(getProperty(key)) { "Missing property: $key" }

    private fun parseMariaDbConfiguration(jdbcUrl: String): Any {
        val configurationClass = Class.forName("org.mariadb.jdbc.Configuration")
        return configurationClass.getMethod("parse", String::class.java).invoke(null, jdbcUrl)
    }

    private fun invoke(target: Any, methodName: String): Any? =
        target.javaClass.getMethod(methodName).invoke(target)
}
