# Laravel Cloud

This throwaway fork tests the minimum changes required to run Campfire (Rails, early-access Ruby
runtime) on Laravel Cloud. Cloud-provisioned resource credentials are never set manually; attaching
each resource supplies its managed environment variables.

## Runtime

- Build: `SECRET_KEY_BASE_DUMMY=1 bundle exec rails assets:precompile`
- Deploy (Cloud "deploy command"): `bin/rails db:prepare`
- Web start command (Cloud, dashboard-only): `bin/start-app`, which `exec`s `bundle exec puma -C config/puma.rb`.
- Background process (worker cluster): `FORK_PER_JOB=false INTERVAL=0.1 bundle exec resque-pool`
- App variables set by us: `SKIP_TELEMETRY=true`, `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`,
  `SECRET_KEY_BASE`, and `PUMA_BIND_HOST=[::]`. **Do NOT set `DISABLE_SSL`** (see below).

## The five things that had to be discovered live

Each of these fails with a message the Cloud **API/CLI never surfaces** — the CLI only ever reports
`deploy.app.crashing` for a boot failure, and 500s only appear in the app logs. Every one was found by
reading `cloud environment:logs` (and, for one, Ed reading the dashboard's deploy-log detail pane).

1. **IPv6-only network — the #1 gotcha.** Laravel Cloud runs app containers on an IPv6-only network.
   Puma's default bind `tcp://0.0.0.0:$PORT` (IPv4) is unreachable, so every deploy failed
   `deploy.app.crashing` even though Puma booted cleanly and answered `/up` 200 on localhost. Puma must
   bind the IPv6 wildcard `tcp://[::]:$PORT`. We made `config/puma.rb`'s bind host env-driven and set
   `PUMA_BIND_HOST=[::]`. **Also:** `bin/rails server` overrides the config file's `bind` with its own
   host/port, so `bin/start-app` must start Puma directly (`puma -C config/puma.rb`), not via
   `rails server`. This explanation exists ONLY in the dashboard deploy log.

2. **TLS terminates at the edge — don't disable SSL.** `DISABLE_SSL=true` turned off `assume_ssl`, so
   Rails saw the request as `http://` while the browser Origin was `https://`, and every form POST
   (starting with the first-run wizard) returned 422 on CSRF origin check. Removing `DISABLE_SSL`
   restores `assume_ssl`/`force_ssl`, which is correct behind Cloud's TLS-terminating proxy.

3. **Managed Valkey ACL blocks `CLIENT SETNAME`.** The injected `application` Redis user has no
   permission for `client|setname`. Action Cable's default Redis connector passes a connection `:id`,
   which triggers `CLIENT SETNAME` on connect and raised `Redis::PermissionError` (NOPERM) on every
   broadcast — 500 on message creation. `config/initializers/action_cable_redis.rb` installs a connector
   that drops `:id`. (Resque and the cache pool were unaffected.)

4. **S3-compatible storage rejects double checksums.** `aws-sdk-s3` adds a default CRC32 checksum to
   every upload on top of Active Storage's MD5; Cloud's object storage answers
   `InvalidRequest: You can only specify one non-default checksum at a time` — the upload PUT succeeds
   and then a follow-up call 500s. `config/storage.yml` sets `request_checksum_calculation: when_required`
   and `response_checksum_validation: when_required` on the `cloud` service.

5. **Action Cable WebSockets do NOT upgrade through Cloud's edge.** `wss://…/cable` returns **520**
   (Cloudflare "origin returned unknown error"). Cloud's own nginx web proxy (`:8080 → 127.0.0.1:3000`)
   sets `proxy_set_header Connection "";` and never forwards the `Upgrade` header, so a WebSocket to the
   app's Puma can't be established. Rails/Action Cable is healthy in-process (a non-WS GET to `/cable`
   gets Action Cable's own 404 "Page not found" with Rails `x-runtime`), but the edge/proxy path can't
   carry the upgrade. This is a **platform limitation**, not an app bug; Campfire's realtime (post
   appears for other users without reload) does not work on Cloud today. Cloud's managed WebSockets are
   a Laravel/Reverb (Pusher-protocol) product and are not compatible with Action Cable, so they are not
   a drop-in. Not worked around, per brief.

## Cloud Resources

The production environment requires an attached Postgres database, Valkey cache, and private
object-storage bucket. **Do not** add database, cache, or bucket variables yourself — attaching each
resource injects them.

### Cloud-injected environment variable names (Rails runtime)

Captured from a live instance (values never recorded):

- Database: `DATABASE_URL`
- Cache: `REDIS_URL`
- Object storage: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_BUCKET`, `AWS_DEFAULT_REGION`,
  `AWS_REGION`, `AWS_ENDPOINT`, `AWS_ENDPOINT_URL`, `AWS_USE_PATH_STYLE_ENDPOINT`,
  `AWS_EC2_METADATA_DISABLED`
- Web/proxy: `PORT` (=3000), `NGINX_UPSTREAM_PORT` (=3000), `NGINX_CACHE_DEFAULT`, `NGINX_CACHE_FLOOR`,
  `NGINX_HTTP_TIMEOUT`, `NGINX_WORKER_PROCESSES`
- Platform: `APP_URL`, `SSL_MODE`, `RACK_ENV`, `RAILS_ENV`, `RAILS_LOG_TO_STDOUT`, `LARAVEL_CLOUD`,
  `LARAVEL_CLOUD_APP_NAME`, `LARAVEL_CLOUD_BUILD_NUMBER`, `LARAVEL_CLOUD_COMMIT`,
  `LARAVEL_CLOUD_COMMIT_SHA`, `LARAVEL_CLOUD_DEPLOY`, `LARAVEL_CLOUD_DEPLOY_UUID`,
  `LARAVEL_CLOUD_ENV_BRANCH`, `LARAVEL_CLOUD_ENV_NAME`, `LARAVEL_CLOUD_ENV_UUID`, `LARAVEL_CLOUD_REGION`

## CLI vs. dashboard steps

- **CLI can do:** create app/env/DB/cache/bucket; set env vars (`environment:variables`); set build &
  deploy commands (`environment:update --build-command/--deploy-command`); create instances
  (`instance:create --type=app|worker`) and background processes (`background-process:create`); deploy
  (`cloud deploy`); read logs and run one-off commands (`command:run`).
- **Dashboard-only:** attaching DB/cache/bucket resources to the environment; the **web start command**
  (captured from the Procfile at app creation — no CLI flag, not in the public OpenAPI); reading the
  human-readable **deploy failure detail** (the API reduces every boot failure to `deploy.app.crashing`).
- **CLI traps found:** `background-process:delete` silently no-ops (use `:update` to change the command,
  or delete the instance); `instance:create` defaults to `type=service` (use `--type=worker` for the
  Resque cluster); `instance:update --scale-to-zero=false` 422s unless a `--scale-to-zero-timeout` is
  also passed, and the environment's `usesHibernation` read is unreliable.

## Upstream Files Edited

- `Gemfile`, `Gemfile.lock`: replace SQLite with PostgreSQL and add the S3 SDK.
- `config/database.yml`: PostgreSQL from Cloud-injected `DATABASE_URL`.
- `config/storage.yml`: S3 service from injected AWS vars; disable aws-sdk double checksum (#4 above).
- `config/environments/production.rb`: select the S3 (`cloud`) storage service.
- `config/puma.rb`: env-driven bind host so production can use IPv6 `[::]` (#1 above).
- `db/migrate/20231215043540_create_initial_schema.rb`: PostgreSQL full-text index table instead of FTS5.
- `db/migrate/20251126115722_change_active_to_status_on_users.rb`: portable boolean literal.
- `db/schema.rb`: regenerated from PostgreSQL.
- `app/models/message/searchable.rb`: PostgreSQL search index query/maintenance.
- `app/models/user.rb`: case-insensitive autocomplete on PostgreSQL.
- `bin/start-app`: start Puma directly (so config bind applies), migrations run in the deploy command.
- `Procfile`: `web:` runs `bin/start-app` without wrapping Puma in Thruster.

### New files (no upstream counterpart, no merge risk)

- `config/initializers/action_cable_redis.rb`: drop `:id` from the Action Cable Redis connector (#3).
- `.cloud/config.json`: experiment-specific Cloud binding.
