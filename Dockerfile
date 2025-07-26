FROM node:18-slim as builder
WORKDIR /work
RUN rm -rf /work/* /work/.* || true
RUN apt-get update && apt-get install -y openssl ca-certificates git python3 make g++ build-essential libc6-dev libssl-dev libffi-dev pkg-config curl ca-certificates && rm -rf /var/lib/apt/lists/*
RUN corepack enable
COPY package.json yarn.lock ./
COPY . .
RUN sed -i '/generator client {/,/}/ s/provider = "prisma-client-js"/provider = "prisma-client-js"\n  binaryTargets = ["native", "linux-arm64-openssl-3.0.x"]/' packages/prisma/schema.prisma
RUN yarn install --immutable --network-timeout 600000
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
WORKDIR /work/apps/web
RUN NEXTAUTH_SECRET="${NEXTAUTH_SECRET}" CALENDSO_ENCRYPTION_KEY="${CALENDSO_ENCRYPTION_KEY}" NEXTAUTH_URL="${NEXTAUTH_URL}" SITE_URL="${SITE_URL}" NEXT_PUBLIC_WEBAPP_URL="${NEXT_PUBLIC_WEBAPP_URL}" yarn build
RUN echo "Contenido de /work/packages/ en la etapa BUILDER (DIAGNÓSTICO):"
RUN ls -laR /work/packages/ || true
RUN echo "Contenido de /work/apps/web/types/ en la etapa BUILDER (DIAGNÓSTICO):"
RUN ls -laR /work/apps/web/types/ || true

FROM node:18-slim as runner
WORKDIR /app
RUN corepack enable # <--- ¡ESTA ES LA LÍNEA CRÍTICA AÑADIDA!
RUN apt-get update && apt-get install -y openssl ca-certificates curl && rm -rf /var/lib/apt/lists/*

# Copiar los archivos de configuración de Yarn Berry de la raíz del monorepo
COPY --from=builder /work/.yarn ./.yarn
COPY --from=builder /work/.pnp.cjs ./.pnp.cjs # Corregido para que copie a /app
COPY --from=builder /work/package.json ./package.json
COPY --from=builder /work/yarn.lock ./yarn.lock

# Copiar la salida de construcción de la aplicación web y sus recursos
COPY --from=builder /work/apps/web/.next ./.next
COPY --from=builder /work/apps/web/public ./public
COPY --from=builder /work/apps/web/app ./app
COPY --from=builder /work/apps/web/next.config.js ./next.config.js
COPY --from=builder /work/apps/web/tsconfig.json ./tsconfig.json
COPY --from=builder /work/apps/web/components ./components
COPY --from=builder /work/apps/web/lib ./lib

# Copiar las carpetas node_modules (aunque Yarn Berry las maneje de forma diferente, las incluimos)
COPY --from=builder /work/node_modules ./node_modules
COPY --from=builder /work/apps/web/node_modules ./apps/web/node_modules

# Copiar el directorio 'packages' que es crucial para un monorepo de Cal.com
COPY --from=builder /work/packages ./packages

EXPOSE 3000
CMD ["yarn", "start"]
