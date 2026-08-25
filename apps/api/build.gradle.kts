plugins {
	kotlin("jvm") version "2.0.10"
	kotlin("plugin.spring") version "2.0.10"
	id("org.springframework.boot") version "3.5.7"
	id("io.spring.dependency-management") version "1.1.7"
	id("org.flywaydb.flyway") version "11.7.2"
}

group = "com.nagi4757.ec"
version = "0.0.1-SNAPSHOT"
description = "api"

java { toolchain { languageVersion = JavaLanguageVersion.of(21) } }
repositories { mavenCentral() }

dependencies {
	implementation("org.springframework.boot:spring-boot-starter-validation")
	implementation("org.springframework.boot:spring-boot-starter-web")
	implementation("org.springframework.boot:spring-boot-starter-security")
	implementation("org.springframework.boot:spring-boot-starter-actuator")
	implementation("org.springframework.boot:spring-boot-starter-data-redis")
	implementation("com.fasterxml.jackson.module:jackson-module-kotlin")
	implementation("org.jetbrains.kotlin:kotlin-reflect")
	implementation("io.jsonwebtoken:jjwt-api:0.12.6")
	runtimeOnly("io.jsonwebtoken:jjwt-impl:0.12.6")
	runtimeOnly("io.jsonwebtoken:jjwt-jackson:0.12.6")

	// MyBatis + MariaDB
	implementation("org.mybatis.spring.boot:mybatis-spring-boot-starter:3.0.5")
	runtimeOnly("org.mariadb.jdbc:mariadb-java-client:3.5.6")

	// Flyway (앱 기동 시 자동 마이그레이션)
	implementation("org.flywaydb:flyway-core:11.7.2")
	implementation("org.flywaydb:flyway-mysql:11.7.2")

	// 테스트
	testImplementation("org.springframework.boot:spring-boot-starter-test")
	testImplementation("org.springframework.boot:spring-boot-testcontainers")
	testImplementation("org.jetbrains.kotlin:kotlin-test-junit5")
	testImplementation("org.mybatis.spring.boot:mybatis-spring-boot-starter-test:3.0.5")
	testImplementation("org.testcontainers:testcontainers")
	testImplementation("org.testcontainers:junit-jupiter")
	testImplementation("org.testcontainers:mariadb")
	testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.named<org.springframework.boot.gradle.tasks.run.BootRun>("bootRun") {
	if (!System.getenv().containsKey("SPRING_PROFILES_ACTIVE")) {
		environment("SPRING_PROFILES_ACTIVE", "local")
	}
}

tasks.named<Test>("test") {
	useJUnitPlatform {
		excludeTags("integration")
	}
}

tasks.register<Test>("integrationTest") {
	group = "verification"
	description = "Runs Testcontainers integration tests."
	testClassesDirs = sourceSets["test"].output.classesDirs
	classpath = sourceSets["test"].runtimeClasspath
	dependsOn(tasks.named("testClasses"))
	shouldRunAfter(tasks.named("test"))
	// Testcontainers 1.21.3 defaults to an API version rejected by Docker 29.
	val dockerApiVersion = System.getProperty("api.version")
		?: System.getenv("DOCKER_API_VERSION")
		?: "1.44"
	systemProperty("api.version", dockerApiVersion)
	useJUnitPlatform {
		includeTags("integration")
	}
}
