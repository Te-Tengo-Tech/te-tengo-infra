# Fallback image of te-tengo-general-api for the local test, used only when the checkout has no
# Dockerfile of its own (the API's release Dockerfile has the same shape: Temurin 25, user 10001).
FROM eclipse-temurin:25-jdk AS build
WORKDIR /workspace
COPY gradlew settings.gradle.kts build.gradle.kts gradle.properties ./
COPY gradle/ gradle/
RUN --mount=type=cache,target=/root/.gradle \
    ./gradlew --no-daemon --quiet dependencies --configuration runtimeClasspath > /dev/null
COPY src/main/ src/main/
RUN --mount=type=cache,target=/root/.gradle \
    ./gradlew --no-daemon bootJar \
 && find build/libs -name '*.jar' ! -name '*-plain.jar' -exec cp {} application.jar \; \
 && java -Djarmode=tools -jar application.jar extract --layers --destination extracted

FROM eclipse-temurin:25-jre
RUN groupadd --system --gid 10001 tetengo \
 && useradd --system --uid 10001 --gid tetengo --home-dir /app --no-create-home --shell /usr/sbin/nologin tetengo
WORKDIR /app
COPY --from=build /workspace/extracted/dependencies/ ./
COPY --from=build /workspace/extracted/spring-boot-loader/ ./
COPY --from=build /workspace/extracted/snapshot-dependencies/ ./
COPY --from=build /workspace/extracted/application/ ./
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "application.jar"]
