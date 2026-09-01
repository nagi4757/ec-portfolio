package com.nagi4757.ec.api.common.config

import org.assertj.core.api.Assertions.assertThat
import org.junit.jupiter.api.Test
import java.util.Properties

class DemoRuntimeProfileConfigurationTest {

    @Test
    fun `demo database enforces RDS connector identity verification`() {
        val properties = loadProperties()
        val jdbcUrl = properties.required("spring.datasource.url")

        assertThat(jdbcUrl).isEqualTo(
            "jdbc:mariadb://\${DB_HOST}:\${DB_PORT:3306}/\${DB_NAME}" +
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
                .replace("\${DB_PORT:3306}", "3306")
                .replace("\${DB_NAME}", "ec")
        )
        assertThat(invoke(parsed, "sslMode").toString()).isEqualTo("VERIFY_FULL")
        assertThat(invoke(parsed, "serverSslCert")).isEqualTo(
            "/etc/ssl/certs/aws-rds-ap-northeast-1-bundle.pem"
        )
        assertThat(invoke(parsed, "fallbackToSystemTrustStore")).isEqualTo(false)
    }

    @Test
    fun `demo redis uses unauthenticated plaintext connection for private Docker network`() {
        val properties = loadProperties()

        assertThat(properties.required("spring.data.redis.host")).isEqualTo("\${REDIS_HOST}")
        assertThat(properties.required("spring.data.redis.port")).isEqualTo("\${REDIS_PORT:6379}")
        assertThat(properties.required("spring.data.redis.ssl.enabled")).isEqualTo("false")
        assertThat(properties.getProperty("spring.data.redis.username")).isNull()
        assertThat(properties.getProperty("spring.data.redis.password")).isNull()
        assertThat(properties.getProperty("spring.data.redis.url")).isNull()
        assertThat(properties.entries.joinToString())
            .doesNotContain("REDIS_USERNAME")
            .doesNotContain("REDIS_PASSWORD")
    }

    @Test
    fun `demo runtime requires secrets and configures operational defaults`() {
        val properties = loadProperties()

        assertThat(properties.required("management.endpoint.health.group.readiness.include"))
            .isEqualTo("readinessState,db,redis")
        assertThat(properties.required("app.auth.jwt.secret")).isEqualTo("\${APP_AUTH_JWT_SECRET}")
        assertThat(properties.required("app.cors.allowed-origins"))
            .isEqualTo("\${APP_CORS_ALLOWED_ORIGINS}")
        assertThat(properties.required("app.openapi.enabled")).isEqualTo("\${APP_OPENAPI_ENABLED:false}")
        assertThat(properties.required("logging.structured.format.console")).isEqualTo("ecs")
        assertThat(properties.required("logging.structured.ecs.service.environment")).isEqualTo("demo")
    }

    private fun loadProperties(): Properties =
        Properties().apply {
            DemoRuntimeProfileConfigurationTest::class.java.classLoader
                .getResourceAsStream("application-demo.properties").use { input ->
                requireNotNull(input) { "Missing test resource: application-demo.properties" }
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
