FROM node:18-slim as builder
WORKDIR /work
RUN rm -rf /work/* /work/.* || true
RUN apt-get update && apt-get install -y openssl ca-certificates git python3 make g++ build-essential libc6-dev libssl-dev libffi-dev pkg-config curl ca-certificates && rm -rf /var/lib/apt/lists/*
RUN corepack enable
COPY package.json yarn.lock ./
COPY . .
RUN echo "nodeLinker: node-modules" > ./.yarnrc.yml # Mantener esta línea para consistencia
RUN sed -i '/generator client {/,/}/ s/provider = "prisma-client-js"/provider = "prisma-client-js"\n  binaryTargets = ["native", "linux-arm64-openssl-3.0.x"]/' packages/prisma/schema.prisma
RUN yarn install --immutable --network-timeout 600000

# Estos pasos de build intermedios para tRPC/Prisma son necesarios para el runner
RUN cd packages/prisma && npx prisma generate --schema=./schema.prisma --no-engine && cd ../..
RUN cd packages/trpc && NODE_OPTIONS="--max-old-space-size=10240" yarn build && cd ../..

# Diagnósticos previos eliminados ya que no serán relevantes
# RUN echo "Contenido de /work/apps/web/node_modules/ antes de yarn build:"
# RUN ls -la /work/apps/web/node_modules/ || true
# RUN echo "Contenido de /work/node_modules/ antes de yarn build:"
# RUN ls -la /work/node_modules/ || true

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
WORKDIR /work/apps/web # Este WORKDIR es para el yarn build de Cal.com
RUN NEXTAUTH_SECRET="${NEXTAUTH_SECRET}" CALENDSO_ENCRYPTION_KEY="${CALENDSO_ENCRYPTION_KEY}" NEXTAUTH_URL="${NEXTAUTH_URL}" SITE_URL="${SITE_URL}" NEXT_PUBLIC_WEBAPP_URL="${NEXT_PUBLIC_WEBAPP_URL}" yarn build
RUN echo "Contenido de /work/packages/ en la etapa BUILDER (DIAGNÓSTICO):"
RUN ls -laR /work/packages/ || true
RUN echo "Contenido de /work/apps/web/types/ en la etapa BUILDER (DIAGNÓSTICO):"
RUN ls -laR /work/apps/web/types/ || true

# =========================================================================================
# === INICIO DE CAMBIOS RADICALES EN LA ETAPA RUNNER ===
# =========================================================================================

FROM node:18-slim as runner
WORKDIR /app
RUN apt-get update && apt-get install -y openssl ca-certificates curl && rm -rf /var/lib/apt/lists/*
RUN corepack enable # Todavía lo necesitamos para yarn start

# Copiar solo el código fuente y los archivos de configuración de Yarn/Node
COPY --from=builder /work/package.json ./package.json
COPY --from=builder /work/yarn.lock ./yarn.lock
COPY --from=builder /work/.yarnrc.yml ./.yarnrc.yml # Copiamos la configuración de node_modules

# Copiar todo el código fuente del monorepo
COPY --from=builder /work/apps/web ./apps/web
COPY --from=builder /work/packages ./packages

# === Ejecutar yarn install *en el runner* ===
# Esto asegura que las dependencias estén instaladas en el contexto correcto del runner
# y que Yarn no se queje de una "instalación faltante".
RUN yarn install --immutable --network-timeout 600000 --production=false # Instalar todas las dependencias
# Note: --production=false es importante para instalar dependencias de desarrollo necesarias para Next.js en el build.
# Si la imagen se vuelve demasiado grande, podemos considerar --production, pero primero que funcione.

# Copiar la salida de construcción de la aplicación web
COPY --from=builder /work/apps/web/.next ./apps/web/.next
COPY --from=builder /work/apps/web/public ./apps/web/public

EXPOSE 3000

# === CMD ajustado para apuntar a la app web dentro del monorepo ===
# Cal.com suele ejecutarse con `yarn workspace web start` o `node ./.next/standalone`
# Vamos a probar la forma que ejecuta el workspace explícitamente.
# Si `yarn start` en la raíz no funciona directamente, puede ser porque espera un workspace.
CMD ["yarn", "workspace", "web", "start"] # <--- ¡CAMBIO AQUÍ!
