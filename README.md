# Infra — Containerized Stack

Docker Compose setup that runs the **whole Nimba platform the way it runs in
production**: the frontend (`web`, Next.js), the backend (`app`, Spring Boot),
PostgreSQL, and MinIO — each service built from its own Dockerfile and started
with its real production command (`pnpm start`, the backend's `java -jar`
entrypoint), not a dev server.

This mirrors the orchestration pattern used by the sibling ADAF project's
`docker/` folder: one `docker-compose.yml` at the top of an infra folder, one
`Dockerfile` living inside each service's own directory (`app/Dockerfile`,
`web/Dockerfile`), and a single env file driving the whole stack.

---

## Overview

- Compose file: [`infra/docker-compose.yml`](docker-compose.yml)
- Env file: `infra/.env` (copy from [`.env.example`](.env.example))
- Services:
  - `web` (Next.js, production build + `pnpm start`) → http://localhost:3000
  - `app` (Spring Boot fat JAR) → http://localhost:8080
  - `postgres` (PostgreSQL 18) → localhost:5433
  - `minio` (S3-compatible object storage) → http://localhost:9000 (API), http://localhost:9001 (console)
  - `minio-init` — one-shot job that creates the app's bucket, then exits
  - `mailpit` (SMTP catch-all, **`dev` profile only**) → http://localhost:8025

Each Dockerfile lives next to the code it builds, not in this folder:

```
app/Dockerfile     → builds the Kotlin/Spring Boot backend (Gradle build → JRE runtime)
web/Dockerfile     → builds the Next.js frontend (pnpm build → pnpm start)
infra/
  docker-compose.yml  → orchestrates web + app + postgres + minio (+ mailpit)
  .env.example        → single source of env vars for the whole stack
  db/                 → backup/restore scripts for the postgres container
```

### How this differs from `app/docker-compose.yml`

`app/docker-compose.yml` is a **different, smaller** file used for day-to-day
backend development: it starts only the infrastructure (postgres, minio,
mailpit) so `./gradlew bootRun` can run the backend natively with hot reload.
`infra/docker-compose.yml` additionally builds and runs the `app` and `web`
containers themselves — this is the "launch it like it runs in production"
path. **Don't run both at once** — by default they claim the same host ports
(5433, 9000/9001, 1025/8025).

| | `app/docker-compose.yml` | `infra/docker-compose.yml` |
|---|---|---|
| Purpose | Local backend development | Full containerized stack ("production-like") |
| Backend runs via | `./gradlew bootRun` (native, hot reload) | `app` container (built JAR) |
| Frontend runs via | `pnpm dev` (native, hot reload) — not started by this file at all | `web` container (built app, `pnpm start`) |
| Services started | postgres, minio, minio-init, mailpit | postgres, minio, minio-init, app, web (+ mailpit with `--profile dev`) |

---

## Prerequisites

- Docker Engine with Compose v2 (`docker compose version`)
- Nothing else — Gradle, the JDK, Node and pnpm are all installed *inside* the
  build stages of `app/Dockerfile` / `web/Dockerfile`; you don't need them on
  the host to run this stack.

## 1. Configure environment

```bash
cd infra
cp .env.example .env
```

Open `.env` and set, at minimum, real values for anything marked as a secret:
`POSTGRES_PASSWORD`, `MINIO_ROOT_PASSWORD`, `MINIO_SECRET_KEY`. For anything
beyond a local trial run, also set:

- `APP_FRONTEND_BASE_URL` / `CORS_ALLOWED_ORIGINS` → the public URL `web` will
  actually be reached at (these two must stay in sync — see the comments in
  `.env.example`)
- `SESSION_COOKIE_SECURE=true` → once the stack is served over HTTPS
- `MAIL_TRANSPORT=resend` + `RESEND_API_KEY` → most hosts block outbound SMTP,
  so production mail should not depend on the local `mailpit` container
- `MINIO_ENDPOINT` in `docker-compose.yml`'s `app` service, plus
  `MINIO_ACCESS_KEY`/`MINIO_SECRET_KEY` → if you're pointing at a hosted
  S3-compatible service instead of the bundled `minio` container

Every variable is documented inline in [`.env.example`](.env.example).

## 2. Build the images

```bash
docker compose build
```

This runs the real production build for each service: `./gradlew bootJar` for
`app` (multi-stage — the Gradle/JDK build stage is discarded, only the JRE +
JAR ship) and `pnpm build` for `web`.

## 3. Launch the stack

```bash
# Production-like: web, app, postgres, minio (no mailpit)
docker compose up -d

# Local full-stack testing: same, plus mailpit so invitation e-mails are
# visible instead of requiring a real SMTP/Resend relay
docker compose --profile dev up -d
```

## 4. Verify

```bash
docker compose ps
docker compose logs -f app web
```

- Frontend: http://localhost:3000
- Backend health: http://localhost:8080/actuator/health
- Backend Swagger UI: http://localhost:8080/swagger-ui/index.html
- MinIO console: http://localhost:9001
- Mailpit UI (with `--profile dev`): http://localhost:8025

The very first time the stack comes up there are no user accounts yet — bootstrap
the first admin from the frontend's `/bootstrap` page (or `POST
/api/v1/auth/bootstrap`); it self-disables after the first account is created.
That admin then invites everyone else.

---

## Useful commands

```bash
docker compose ps                    # list services
docker compose logs -f <service>     # tail logs (app, web, postgres, minio, mailpit)
docker compose restart <service>     # restart one service
docker compose up -d --build <service>  # rebuild + redeploy one service
docker compose stop                  # stop all, keep containers/volumes
docker compose down                  # stop and remove containers (volumes persist)
docker compose down -v               # also delete volumes (DESTROYS the database/objects)
```

## Volumes & persistence

- `pgdata` — PostgreSQL data directory
- `miniodata` — MinIO objects (avatars, organisation logo)
- `app-storage` — original uploaded amortization-schedule CSVs, retained for audit
  (`AMORTIZATION_SCHEDULE_STORAGE_DIR`)
- `app-logs` — the backend's rotated ECS-JSON log file

All four are named volumes, so they survive `docker compose down` /
`docker compose up` cycles and image rebuilds. Only `docker compose down -v`
removes them.

Database backup/restore scripts live in [`db/`](db/README.md).

## Dependencies between services

- `app` waits for `postgres` (healthy) and `minio` + `minio-init` (bucket created)
  before starting
- `web` has no hard dependency on `app` starting first (matches the ADAF
  `client`/`cms` pattern) — it comes up immediately; requests just fail until
  `app` is ready, same as any reverse-proxied deployment

## Ports (host-mapped, override any of them in `.env`)

| Var | Default | Service |
|---|---|---|
| `WEB_PORT` | 3000 | web |
| `APP_PORT` | 8080 | app |
| `POSTGRES_PORT` | 5433 | postgres |
| `MINIO_API_PORT` | 9000 | minio |
| `MINIO_CONSOLE_PORT` | 9001 | minio |
| `MAIL_PORT` | 1025 | mailpit (`dev` profile) |
| `MAILPIT_UI_PORT` | 8025 | mailpit (`dev` profile) |

---

## Troubleshooting

- **`app` exits immediately / restarts in a loop** → `docker compose logs app`;
  almost always a database not yet reachable (check `postgres` is healthy) or a
  missing required secret.
- **Frontend shows network errors calling the API** → check `docker compose
  logs web`; `BACKEND_ORIGIN` (set automatically to `http://app:8080` inside
  the compose network) is what `next.config.ts`'s proxy forwards `/api/*` to.
- **Invitation e-mails never arrive** → in the default profile there is no mail
  relay; either run with `--profile dev` (mailpit) or set `MAIL_TRANSPORT=resend`
  with a valid `RESEND_API_KEY`.
- **MinIO bucket errors on first boot** → `minio-init` must complete before
  `app` starts; check `docker compose logs minio-init` — it should exit 0.
- **Port already in use** → another instance of this stack, `app/docker-compose.yml`,
  or a native `./gradlew bootRun` / `pnpm dev` is already bound to that port;
  stop it or remap the port in `.env`.
- **Set-password link in an invitation e-mail points at `localhost`** →
  `APP_FRONTEND_BASE_URL` was left at its default; set it to the real public URL.

---
Keep this doc aligned with `docker-compose.yml` and `.env.example` as the stack evolves.
