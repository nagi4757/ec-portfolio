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

val dbHost = System.getenv("DB_HOST") ?: "127.0.0.1"
val dbPort = System.getenv("DB_PORT") ?: "3307"
val dbName = System.getenv("DB_NAME") ?: "ec"
val dbUsername = System.getenv("DB_USERNAME") ?: "ec_user"
val dbPassword = System.getenv("DB_PASSWORD") ?: "ec_pass"

java { toolchain { languageVersion = JavaLanguageVersion.of(21) } }
repositories { mavenCentral() }

val mbg by configurations.creating

dependencies {
	implementation("org.springframework.boot:spring-boot-starter-validation")
	implementation("org.springframework.boot:spring-boot-starter-web")
	implementation("org.springframework.boot:spring-boot-starter-security")
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
	testImplementation("org.jetbrains.kotlin:kotlin-test-junit5")
	testImplementation("org.mybatis.spring.boot:mybatis-spring-boot-starter-test:3.0.5")
	testRuntimeOnly("org.junit.platform:junit-platform-launcher")

	// MBG
	mbg("org.mybatis.generator:mybatis-generator-core:1.4.2")
	mbg("com.mysql:mysql-connector-j:8.4.0")
}

/* ./gradlew mbGenerator */
tasks.register<JavaExec>("mbGenerator") {
	doFirst {
		file("build/generated/mbg/java").mkdirs()
		file("build/generated/mbg/resources").mkdirs()
	}
	group = "codegen"
	description = "Run MyBatis Generator"
	classpath = configurations["mbg"]
	mainClass.set("org.mybatis.generator.api.ShellRunner")
	jvmArgs(
		"-Djavax.xml.accessExternalDTD=all",
		"-Djavax.xml.accessExternalSchema=all",
		"-DDB_HOST=$dbHost",
		"-DDB_PORT=$dbPort",
		"-DDB_NAME=$dbName",
		"-DDB_USERNAME=$dbUsername",
		"-DDB_PASSWORD=$dbPassword"
	)
	args = listOf(
		"-configfile", "src/main/resources/mbg/generatorConfig.xml",
		"-overwrite",
		"-verbose",
		"-contextids", "ec"
	)
}

sourceSets {
	named("main") {
		java.srcDir("build/generated/mbg/java")
		resources.srcDir("build/generated/mbg/resources")
	}
}

tasks.register("mbgClean") { doLast { delete("build/generated/mbg") } }
tasks.named("mbGenerator") { dependsOn("mbgClean") }

tasks.named("compileKotlin") { dependsOn("mbGenerator") }
tasks.named("compileJava") { dependsOn("mbGenerator") }

tasks.named<org.springframework.boot.gradle.tasks.run.BootRun>("bootRun") {
	environment("DB_HOST", System.getenv("DB_HOST") ?: "127.0.0.1")
	environment("DB_PORT", System.getenv("DB_PORT") ?: "3307")
	environment("DB_NAME", System.getenv("DB_NAME") ?: "ec")
	environment("DB_USERNAME", System.getenv("DB_USERNAME") ?: "ec_user")
	environment("DB_PASSWORD", System.getenv("DB_PASSWORD") ?: "ec_pass")
	environment("REDIS_HOST", System.getenv("REDIS_HOST") ?: "127.0.0.1")
	environment("REDIS_PORT", System.getenv("REDIS_PORT") ?: "6380")
}

tasks.withType<Test> { useJUnitPlatform() }
