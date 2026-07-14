FROM eclipse-temurin:21-jdk
WORKDIR /workspace

COPY gradlew gradlew
COPY gradle gradle
COPY build.gradle.kts settings.gradle.kts ./
COPY src src

RUN chmod +x gradlew

EXPOSE 8080
ENTRYPOINT ["./gradlew", "bootRun", "--no-daemon"]

