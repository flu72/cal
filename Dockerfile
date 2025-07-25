# Dockerfile para Cal.com - Build Personalizado Final (AxisNode)
# Resuelve todos los problemas de build y asegura la propagación de variables

# Base para la etapa de construcción (builder)
FROM node:18-slim as builder

# Establecer el directorio de trabajo
WORKDIR /work

# Limpiar el directorio de trabajo para evitar residuos inesperados
RUN rm -rf /work/* /work/.* || true

# Instalar dependencias necesarias para el build
RUN apt-get update && apt-get install -y \
    openssl \
    ca-certificates \
    git \
    python3 \
    make \
    g++ \
    build-essential \
    libc6-dev \
    libssl-dev \
    libffi-dev \
    pkg-config \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Habilitar corepack para yarn
RUN corepack enable

# --- INICIO: Secuencia de copia de archivos y dependencias para monorepo ---

# 1. Copiar los archivos package.json y yarn.lock de la raíz
# Esto es una optimización temprana para la capa de yarn install si solo cambian estos.
COPY package.json yarn.lock ./

# 2. Copiar todo el código fuente del monorepo
# CRÍTICO: Esto debe ocurrir ANTES de yarn install para que todos los workspaces sean visibles.
COPY . .

# 3. Modificar schema.prisma para incluir binaryTargets de ARM64
# Esta línea debe ir DESPUÉS del COPY . . para que el archivo packages/prisma/schema.prisma exista.
RUN sed -i '/generator client {/,/}/ s/provider = "prisma-client-js"/provider = "prisma-client-js"\n  binaryTargets = ["native", "linux-arm64-openssl-3.0.x"]/' packages/prisma/schema.prisma

# 4. Instalar todas las dependencias del monorepo
# 'yarn cache clean' ha sido eliminado para permitir el cacheo de Docker.
RUN yarn install --immutable --network-timeout 600000

# 5. Generar Prisma Client
# Esta línea debe ir DESPUÉS de que el schema haya sido modificado y las dependencias instaladas.
RUN cd packages/prisma && npx prisma generate --schema=./schema.prisma --no-engine && cd ../..

# --- NUEVO PASO: Construir paquetes internos para generar tipos y artefactos ---
# Esto es crucial para que el compilador de TypeScript encuentre los módulos internos.
# AJUSTE DE MEMORIA: 10240MB = 10GB para el build de trpc.
RUN cd packages/trpc && NODE_OPTIONS="--max-old-space-size=10240" yarn build && cd ../..

# 🚨 Variables necesarias ANTES del build (incluyendo NEXT_PUBLIC_WEBAPP_URL)
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

# Establecer opciones de Node.js para el build de la aplicación principal (8GB, la configuración que tenías)
ENV NODE_OPTIONS="--max-old-space-size=8192"

# CRÍTICO: Moverse al directorio correcto antes del build de la aplicación
WORKDIR /work/apps/web

# **NUEVO: Construir la aplicación web pasando las variables de entorno directamente**
# Esto es CRUCIAL para que Next.js las reconozca en el build-time.
RUN NEXTAUTH_SECRET="${NEXTAUTH_SECRET}" \
    CALENDSO_ENCRYPTION_KEY="${CALENDSO_ENCRYPTION_KEY}" \
    NEXTAUTH_URL="${NEXTAUTH_URL}" \
    SITE_URL="${SITE_URL}" \
    NEXT_PUBLIC_WEBAPP_URL="${NEXT_PUBLIC_WEBAPP_URL}" \
    yarn build

# --- INICIO DEPURACIÓN AVANZADA (Builder Stage) ---
# Estos comandos listan el contenido de los directorios problemáticos EN LA ETAPA BUILDER
RUN echo "Contenido de /work/packages/ en la etapa BUILDER (DIAGNÓSTICO):"
RUN ls -laR /work/packages/ || true
RUN echo "Contenido de /work/apps/web/types/ en la etapa BUILDER (DIAGNÓSTICO):"
RUN ls -laR /work/apps/web/types/ || true
# --- FIN DEPURACIÓN AVANZADA (Builder Stage) ---


# =========================================================================

# → RUNNER: Etapa de ejecución final

FROM node:18-slim as runner

# Establecer el directorio de trabajo
WORKDIR /app

# Instalar dependencias necesarias para el runtime (ej. openssl, curl para la DB)
RUN apt-get update && apt-get install -y \
    openssl \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# 🚨 CRÍTICO: AJUSTE DE RUTAS para Next.js en monorepo (apps/web)
# Ahora las rutas de origen son correctas
COPY --from=builder /work/apps/web/.next ./.next
COPY --from=builder /work/apps/web/public ./public
COPY --from=builder /work/package.json ./package.json
COPY --from=builder /work/yarn.lock ./yarn.lock

# Copiar node_modules del builder
# Mantenemos solo las copias de los node_modules principales que realmente existen
COPY --from=builder /work/node_modules ./node_modules
COPY --from=builder /work/apps/web/node_modules ./apps/web/node_modules

# Copiar el resto de la aplicación (solo lo necesario para el runtime)
# Copia solo los archivos de apps/web/app ya que es el punto de entrada de Next.js
COPY --from=builder /work/apps/web/app ./app
COPY --from=builder /work/apps/web/next.config.js ./next.config.js
COPY --from=builder /work/apps/web/tsconfig.json ./tsconfig.json

# Copiar otros directorios de apps/web si son necesarios en runtime
COPY --from=builder /work/apps/web/components ./components
COPY --from=builder /work/apps/web/lib ./lib
COPY --from=builder /work/apps/web/types ./types # <-- Mantenemos esta, si aún falla, significa que /work/apps/web/types no existe en el builder

# Copiar TODOS los paquetes fuente (si son necesarios en runtime) de una sola vez
# Esto es más robusto para un monorepo, ya que copia todas las subcarpetas de 'packages'
COPY --from=builder /work/packages ./packages # <--- NUEVO: Copia todo el directorio 'packages'

# Exponer el puerto
EXPOSE 3000

# Comando para ejecutar la aplicación
CMD ["yarn", "start"]
