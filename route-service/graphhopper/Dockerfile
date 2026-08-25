# Self-hosted GraphHopper. Not GraphHopper Cloud: there is no API key anywhere
# in this image. The runnable web jar is pulled from Maven Central at build
# time and pinned, so a rebuild six months from now is the same engine.
FROM eclipse-temurin:21-jre-noble

ARG GRAPHHOPPER_VERSION=11.0
ENV GRAPHHOPPER_VERSION=${GRAPHHOPPER_VERSION}

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /gh
RUN curl -fsSL -o graphhopper-web.jar \
      "https://repo1.maven.org/maven2/com/graphhopper/graphhopper-web/${GRAPHHOPPER_VERSION}/graphhopper-web-${GRAPHHOPPER_VERSION}.jar"

COPY config.yml /gh/config.yml
COPY looper_foot.json /gh/looper_foot.json
COPY entrypoint.sh /gh/entrypoint.sh
RUN chmod +x /gh/entrypoint.sh && mkdir -p /data/osm /data/graph-cache

EXPOSE 8989
# /info is GraphHopper's own "which area am I serving" endpoint and only answers
# once the graph is loaded, which is exactly what readiness means here.
HEALTHCHECK --interval=15s --timeout=5s --start-period=180s --retries=20 \
  CMD curl -fsS http://localhost:8989/info > /dev/null || exit 1

ENTRYPOINT ["/gh/entrypoint.sh"]
CMD ["serve"]
