FROM eclipse-temurin:21.0.12_8-jdk-noble AS builder
WORKDIR /workspace

COPY gradlew gradlew
COPY gradle gradle
COPY build.gradle.kts settings.gradle.kts ./
RUN chmod +x gradlew
RUN ./gradlew dependencies --no-daemon

COPY src/main src/main
RUN set -eu; \
    ./gradlew clean bootJar --no-daemon; \
    mkdir -p /out; \
    jar_count="$(find build/libs -maxdepth 1 -type f -name '*.jar' ! -name '*-plain.jar' | wc -l)"; \
    test "$jar_count" -eq 1; \
    find build/libs -maxdepth 1 -type f -name '*.jar' ! -name '*-plain.jar' \
        -exec cp '{}' /out/app.jar \;

FROM eclipse-temurin:21.0.12_8-jre-noble
WORKDIR /app

RUN groupadd --system --gid 10001 appgroup \
    && useradd --system --uid 10001 --gid appgroup appuser

COPY --from=builder --chmod=0444 /out/app.jar /app/app.jar
COPY --chown=0:0 --chmod=0444 docker/aws-rds-ap-northeast-1-bundle.pem /etc/ssl/certs/aws-rds-ap-northeast-1-bundle.pem

USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
