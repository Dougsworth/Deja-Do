FROM oven/bun:1.2.23
WORKDIR /app
COPY package.json ./
COPY src ./src
ENV NODE_ENV=production PORT=3000 DATA_DIR=/data
# A named volume picks up this ownership, so the server can write its usage file.
RUN mkdir -p /data && chown bun:bun /data
VOLUME /data
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s CMD bun -e "fetch('http://localhost:3000/health').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"
USER bun
CMD ["bun", "src/index.ts"]
