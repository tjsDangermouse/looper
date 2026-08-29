# Build and run the Gate 2 harness. Java lives only in here: the point of the
# harness is to measure GraphHopper's own engine, not to install a toolchain on
# the machine that happens to be driving the comparison.
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /h
COPY pom.xml .
# Warm the dependency cache as its own layer so source edits rebuild in seconds.
RUN mvn -q -B -Dmaven.repo.local=/root/.m2/repository dependency:go-offline || true
COPY src ./src
RUN mvn -q -B -Dmaven.repo.local=/root/.m2/repository package

FROM eclipse-temurin:21-jre-noble
WORKDIR /h
COPY --from=build /h/target/gh-harness.jar /h/gh-harness.jar
ENTRYPOINT ["java", "-Xmx2g", "-Xms256m", "-jar", "/h/gh-harness.jar"]
