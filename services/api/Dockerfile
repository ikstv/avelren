FROM node:22-bookworm-slim AS build

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
COPY migrations ./migrations

RUN npm run build \
    && npm prune --omit=dev \
    && npm cache clean --force

FROM node:22-bookworm-slim AS runtime

ENV NODE_ENV=production
WORKDIR /app

RUN groupadd --system --gid 10001 avelren \
    && useradd --system --uid 10001 --gid 10001 --home-dir /app --shell /usr/sbin/nologin avelren

COPY --from=build --chown=avelren:avelren /app/package.json /app/package-lock.json ./
COPY --from=build --chown=avelren:avelren /app/node_modules ./node_modules
COPY --from=build --chown=avelren:avelren /app/dist ./dist
COPY --from=build --chown=avelren:avelren /app/migrations ./migrations

USER 10001:10001

EXPOSE 3000

CMD ["node", "dist/server.js"]
