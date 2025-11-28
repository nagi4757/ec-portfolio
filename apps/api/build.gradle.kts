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

val mbg by configurations.creating

dependencies {
	implementation("org.springframework.boot:spring-boot-starter-validation")
	implementation("org.springframework.boot:spring-boot-starter-web")
	implementation("com.fasterxml.jackson.module:jackson-module-kotlin")
	implementation("org.jetbrains.kotlin:kotlin-reflect")

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
	jvmArgs("-Djavax.xml.accessExternalDTD=all", "-Djavax.xml.accessExternalSchema=all")
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

tasks.withType<Test> { useJUnitPlatform() }
