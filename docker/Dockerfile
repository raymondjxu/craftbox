ARG JAVA_VERSION=25

FROM eclipse-temurin:${JAVA_VERSION}-jre-jammy

# Runtime tools: bash + envsubst (gettext-base) for entrypoint templating.
# (HEALTHCHECK uses bash's /dev/tcp; no nc needed.)
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Create non-root minecraft user
RUN useradd -m -u 1000 -s /bin/bash minecraft

WORKDIR /opt/minecraft

# Copy server jar
COPY server/fabric-server-launch.jar ./fabric-server-launch.jar

# Copy resolved mods (populated by CI)
COPY build/mods/ ./mods/

# Copy mod configs
COPY config/ ./config/

# Copy datapacks (will be deployed to world/datapacks/ on first boot)
COPY datapacks/ ./datapacks/

# Copy server.properties template
COPY docker/server.properties.tmpl ./server.properties.tmpl

# Copy and make entrypoint executable
COPY docker/entrypoint.sh ./entrypoint.sh
RUN chmod +x ./entrypoint.sh

# Bake EULA acceptance into image
RUN echo "eula=true" > ./eula.txt

# Ensure data/log directories exist so volume initialization preserves ownership
RUN mkdir -p /opt/minecraft/data /opt/minecraft/logs \
  && chown -R minecraft:minecraft /opt/minecraft

# Switch to non-root user
USER minecraft

# Expose server port
EXPOSE 25565

# Health check: bash's /dev/tcp probe avoids needing netcat.
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
  CMD bash -c '</dev/tcp/127.0.0.1/25565' || exit 1

ENTRYPOINT ["/opt/minecraft/entrypoint.sh"]
