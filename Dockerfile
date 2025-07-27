# Usa Node 20 para mayor soporte de features, velocidad y seguridad (recomendado si Cal.com soporta Node 20)
FROM node:20-slim as builder
WORKDIR /work

# Limpieza previa
RUN rm -rf /work/* /work/.* || true

# Instala dependencias de sistema necesarias para build
RUN apt-get update && apt-get install -y \
  openssl ca-certificates git python3 make g++ build-essential libc6-dev \
  libssl-dev libffi-dev pkg-config curl \
  && rm -rf /var/lib/apt/lists/*

RUN corepack enable

# Copia package.json y yarn.lock para instalar dependencias primero (mejor cache)
COPY package.json yarn.lock ./

# Copia todo el código y archivos del repo al contexto de build
COPY . .

# CRÍTICO: asegúrate de copiar i18n.json y otros archivos raíz al contenedor
COPY i18n.json ./i18n.json

# Limpia caché de Yarn
RUN yarn cache clean --all

# Opcional: modifica provider si necesitas soporte multi-plataforma (ARM/x86, etc)
RUN sed -i '/generator client {/,/}/ s/provider = "prisma-client-js"/provider = "prisma-client-js"\n  binaryTargets = ["native", "linux-arm64-openssl-3.0.x"]/' packages/prisma/schema.prisma

# Instala dependencias usando Yarn Berry (node-modules linker recomendado)
RUN yarn install --immutable --network-timeout 600000

# Genera Prisma client
RUN cd packages/prisma && npx prisma generate --schema=./schema.prisma --no-engine && cd ../..

# Compila el paquete TRPC (si aplica)
RUN cd packages/trpc && NODE_OPTIONS="--max-old-space-size=10240" yarn build && cd ../..

# Compila la app Next.js (esto es el "yarn build" que faltaba en tu Dockerfile)
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
RUN yarn build

# Fase runner: solo incluye lo necesario para correr la app
FROM node:20-slim as runner
WORKDIR /app
RUN apt-get update && apt-get install -y openssl ca-certificates curl && rm -rf /var/lib/apt/lists/*
RUN corepack enable

# Copia archivos de Yarn Berry y configuración
COPY --from=builder /work/.yarn ./.yarn
COPY --from=builder /work/package.json ./package.json
COPY --from=builder /work/yarn.lock ./yarn.lock
COPY --from=builder /work/.yarnrc.yml ./.yarnrc.yml

# Copia código fuente y paquetes
COPY --from=builder /work/apps/web ./apps/web
COPY --from=builder /work/packages ./packages
COPY --from=builder /work/i18n.json ./i18n.json

# Copia node_modules generados durante build
COPY --from=builder /work/node_modules ./node_modules
COPY --from=builder /work/apps/web/node_modules ./apps/web/node_modules

# Copia salida de build Next.js y assets públicos
COPY --from=builder /work/apps/web/.next ./apps/web/.next
COPY --from=builder /work/apps/web/public ./apps/web/public

EXPOSE 3000

CMD ["yarn", "workspace", "@calcom/web", "start"]
