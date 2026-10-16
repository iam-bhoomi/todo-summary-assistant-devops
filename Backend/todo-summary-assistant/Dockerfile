# syntax=docker/dockerfile:1

# ---- Build stage: full JDK + Maven, discarded after build ----
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /src
# Resolve dependencies first so this layer is cached until pom.xml changes
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -B -q dependency:go-offline
COPY src ./src
# Tests run in the CI pipeline against MySQL, not inside the image build
RUN --mount=type=cache,target=/root/.m2 mvn -B -q package -DskipTests \
 && cp target/*.jar /app.jar

# ---- Runtime stage: JRE only, non-root ----
FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
RUN addgroup -S app && adduser -S -G app -u 10001 app
COPY --from=build --chown=app:app /app.jar app.jar
USER 10001
EXPOSE 8080
# Respect container memory limits; extra flags can be passed via JAVA_OPTS
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"
HEALTHCHECK --interval=15s --timeout=3s --start-period=60s --retries=4 \
  CMD wget -qO- http://localhost:8080/actuator/health || exit 1
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar app.jar"]
