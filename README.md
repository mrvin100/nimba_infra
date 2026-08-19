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
  - `mailpit` (SMTP catch-all — part of the default stack) → http://localhost:8025

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
| Services started | postgres, minio, minio-init, mailpit | postgres, minio, minio-init, app, web, mailpit |

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
- `MAIL_TRANSPORT=resend` + `RESEND_API_KEY` → once the bank wants real
  delivery to external mailboxes instead of reading sent mail from Mailpit's
  web UI (most hosts also block outbound SMTP, which `smtp`/Mailpit needs)
- `MAILPIT_UI_AUTH` → set this (`user:pass`) before exposing `MAILPIT_UI_PORT`
  on a real server; its UI shows every sent e-mail in clear text, including
  password-reset and invitation links
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
docker compose up -d
```

`web` waits for `app`'s healthcheck (`/actuator/health`) before starting, so
there's no need to reload the bootstrap page a few times while the backend is
still finishing its migrations on first boot.

## 4. Verify

```bash
docker compose ps
docker compose logs -f app web
```

- Frontend: http://localhost:3000
- Backend health: http://localhost:8080/actuator/health
- Backend Swagger UI: http://localhost:8080/swagger-ui/index.html
- MinIO console: http://localhost:9001
- Mailpit UI: http://localhost:8025 (put it behind `MAILPIT_UI_AUTH` before
  exposing this on a real server)

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
- `web` waits for `app`'s own healthcheck (`GET /actuator/health`, polled every
  5s once the container has had 30s to boot) before starting — without this, a
  slower first boot (Flyway migrations + JVM warmup can take well past the
  instant `docker compose up` returns) let the frontend query a backend that
  wasn't listening yet

## Ports (host-mapped, override any of them in `.env`)

| Var | Default | Service |
|---|---|---|
| `WEB_PORT` | 3000 | web |
| `APP_PORT` | 8080 | app |
| `POSTGRES_PORT` | 5433 | postgres |
| `MINIO_API_PORT` | 9000 | minio |
| `MINIO_CONSOLE_PORT` | 9001 | minio |
| `MAIL_PORT` | 1025 | mailpit |
| `MAILPIT_UI_PORT` | 8025 | mailpit |

---

## Troubleshooting

- **`app` exits immediately / restarts in a loop** → `docker compose logs app`;
  almost always a database not yet reachable (check `postgres` is healthy) or a
  missing required secret.
- **Frontend shows network errors calling the API, or the bootstrap page says
  "an admin already exists" right after a fresh `docker compose up`** → check
  `docker compose logs app`; the backend is most likely still starting
  (migrations/JVM warmup) — `web` waits for its healthcheck before starting,
  but a request made in the few seconds before that check first passes will
  still fail. The bootstrap page now shows a clear "impossible de contacter le
  serveur" message with a retry button in that case, rather than the
  misleading "already initialized" one. `BACKEND_ORIGIN` (set automatically to
  `http://app:8080` inside the compose network) is what `proxy.ts`'s middleware
  forwards `/api/*` to, read fresh on every request (not baked in at image build
  time, unlike `next.config.ts`'s `rewrites()`).
- **Reads work but every write fails: the bootstrap page loads and reports no
  admin yet, then "créer" fails, and logging in fails too** → the browser is
  reaching `web` at a different origin than `app` believes, and `app` rejects the
  write as cross-origin (its response body is literally `Invalid CORS request`).
  Only writes break, because browsers attach an `Origin` header to `POST`/`PUT`/
  `DELETE` but not to a plain `GET` — which is also why the same call succeeds
  from Swagger UI, served same-origin with the backend. `web`'s proxy sends
  `X-Forwarded-Host`/`-Proto`/`-Port` and `app` honors them
  (`FORWARD_HEADERS_STRATEGY`, default `framework`), so this resolves itself at
  any hostname or port; if you have overridden that variable to `none`, or put
  another proxy in front that strips those headers, restore them rather than
  widening `CORS_ALLOWED_ORIGINS`.
- **Same symptom, but only once you put nginx/Traefik in front for HTTPS** → that
  proxy must pass the browser's original host through, because Next.js rebuilds
  `X-Forwarded-Host` from `Host` and discards any value the front proxy set. With
  nginx that means `proxy_set_header Host $host;` (not `$proxy_host`) alongside
  `proxy_set_header X-Forwarded-Proto $scheme;`. Send `Host: web:3000` instead and
  the backend believes the site lives at `web:3000`, so every write 403s again.
- **Invitation e-mails never arrive** → check `docker compose logs mailpit`
  and confirm `MAIL_TRANSPORT=smtp`/`MAIL_HOST=mailpit`, or set
  `MAIL_TRANSPORT=resend` with a valid `RESEND_API_KEY` for real delivery.
- **MinIO bucket errors on first boot** → `minio-init` must complete before
  `app` starts; check `docker compose logs minio-init` — it should exit 0.
- **Port already in use** → another instance of this stack, `app/docker-compose.yml`,
  or a native `./gradlew bootRun` / `pnpm dev` is already bound to that port;
  stop it or remap the port in `.env`.
- **Set-password link in an invitation e-mail points at `localhost`** →
  `APP_FRONTEND_BASE_URL` was left at its default; set it to the real public URL.

---
Keep this doc aligned with `docker-compose.yml` and `.env.example` as the stack evolves.
