FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /src
COPY pom.xml .
COPY src ./src
RUN mvn -B -DskipTests package \
    && jar="$(find target -maxdepth 1 -type f -name 'server-java-*.jar' ! -name 'original-*')" \
    && test -n "$jar" \
    && cp "$jar" /tmp/server.jar

FROM eclipse-temurin:17-jre-jammy
RUN useradd --system --uid 10001 --home-dir /app app
WORKDIR /app
COPY --from=build /tmp/server.jar /app/server.jar
USER app
EXPOSE 8080
ENV HOST=0.0.0.0 \
    PORT=8080
ENTRYPOINT ["java", "-jar", "/app/server.jar"]
