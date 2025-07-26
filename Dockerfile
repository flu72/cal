FROM node:18-slim as builder
WORKDIR /work
RUN rm -rf /work/* /work/.* || true
RUN apt-get update && apt-get install -y openssl ca-certificates git python3 make g++ build-essential libc6-dev libssl-dev libffi-dev pkg-config curl ca-certificates && rm -rf /var/lib/apt/lists/*
RUN corepack enable
COPY package.json yarn.lock ./
COPY . . # This will now copy .yarnrc.yml if it's in your git repo.
RUN yarn cache clean --all # Clear cache just in case

RUN sed -i '/generator client {/,/}/ s/provider = "prisma-client-js"/provider = "prisma-client-js"\n  binaryTargets = ["native", "linux-arm64-openssl-3.0.x"]/' packages/prisma/schema.prisma
RUN yarn install --immutable --network-timeout 600000

# === NEW DIAGNOSTIC: List content of .yarn after install in builder ===
RUN echo "Content of /work/.yarn/ after yarn install (CRITICAL DIAGNOSIS):"
RUN ls -laR /work/.yarn/ || true
# =====================================================================

RUN cd packages/prisma && npx prisma generate --schema=./schema.prisma --no-engine && cd ../..
RUN cd packages/trpc && NODE_OPTIONS="--max-old-space-size=10240" yarn build && cd ../..
RUN echo "Contenido de /work/apps/web/node_modules/ antes de yarn build:"
RUN ls -la /work/apps/web/node_modules/ || true
RUN echo "Contenido de /work/node_modules/ antes de yarn build:"
RUN ls -la /work/node_modules/ || true
ARG NEXTAUTH_SECRET
ARG CALENDSO_ENCRYPTION_KEY
ARG NEXTAUTH_URL
ARG NEXT_PUBLIC_WEBAPP_URL
ARG SITE_URL
ENV NEXTAUTH_SECRET=${NEXTAUTH_SECRET}
ENV CALENDSO_ENCRYPTION_KEY=${CALENDSO_ENCRYPTION_KEY}
ENV NEXTAUTH_URL=${NEXTAUTH_URL}
ENV SITE_URL=${SITE_URL}
ENV NEXT_PUBLIC_WEBAPP_URL=${NEXT_PUBLIC_WEBAPP_URL}
ENV NODE_OPTIONS="--max-old-space-size=8192"
WORKDIR /work/apps/web # This WORKDIR is for the yarn build of Cal.com
RUN NEXTAUTH_SECRET="${NEXTAUTH_SECRET}" CALENDSO_ENCRYPTION_KEY="${CALENDSO_ENCRYPTION_KEY}" NEXTAUTH_URL="${NEXTAUTH_URL}" SITE_URL="${SITE_URL}" NEXT_PUBLIC_WEBAPP_URL="${NEXT_PUBLIC_WEBAPP_URL}" yarn build
RUN echo "Contenido de /work/packages/ en la etapa BUILDER (DIAGNÓSTICO):"
RUN ls -laR /work/packages/ || true
RUN echo "Contenido de /work/apps/web/types/ en la etapa BUILDER (DIAGNÓSTICO):"
RUN ls -laR /work/apps/web/types/ || true

# =========================================================================================
# === RUNNER STAGE ===
# =========================================================================================

FROM node:18-slim as runner
WORKDIR /app
RUN apt-get update && apt-get install -y openssl ca-certificates curl && rm -rf /var/lib/apt/lists/*
RUN corepack enable # Needed for yarn start

# Copiar los archivos esenciales de Yarn Berry (incluyendo el .yarnrc.yml)
# This assumes the .yarn/releases/yarn-3.4.1.cjs is actually within /work/.yarn/releases/
COPY --from=builder /work/.yarn ./.yarn
COPY --from=builder /work/package.json ./package.json
COPY --from=builder /work/yarn.lock ./yarn.lock
COPY --from=builder /work/.yarnrc.yml ./.yarnrc.yml # Explicitly copy .yarnrc.yml

# Copiar todo el código fuente del monorepo (aplicaciones y paquetes compartidos)
COPY --from=builder /work/apps/web ./apps/web
COPY --from=builder /work/packages ./packages

# === Reverted: Do NOT run yarn install in the runner ===
# The error "Usage Error: The project in /app/package.json doesn't seem to have been installed"
# despite running install in the runner suggests that either the yarn install in the runner
# is not working, or the `yarn workspace web start` command expects the yarn setup
# (i.e. the .yarn folder) to be exactly as it was after the builder install.
# Let's rely on the builder's installation and copying its output.
# RUN yarn install --immutable --network-timeout 600000 --production=false

# Copy the generated node_modules from the builder, which should now exist
# because we're forcing nodeLinker: node-modules in .yarnrc.yml.
# This is crucial if `yarn workspace web start` expects these to be present.
COPY --from=builder /work/node_modules ./node_modules # Copy root node_modules
COPY --from=builder /work/apps/web/node_modules ./apps/web/node_modules # Copy web app specific node_modules

# Copiar la salida de construcción de la aplicación web
COPY --from=builder /work/apps/web/.next ./apps/web/.next
COPY --from=builder /work/apps/web/public ./apps/web/public

EXPOSE 3000

CMD ["yarn", "workspace", "web", "start"]
