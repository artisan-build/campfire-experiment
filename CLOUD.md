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
   a drop-in. Not worked around on `main`; branch `pusher-reverb` carries realtime over Reverb instead
   (see below).

## Realtime over Cloud's managed Reverb (branch `pusher-reverb` only)

Branch `pusher-reverb` carries realtime over Reverb's Pusher protocol instead of Action Cable's
WebSocket, which #5 above makes unusable on Cloud. Nothing in it activates without the `REVERB_*`
variables, so `main`, development, test and CI are unaffected.

- **Server:** `lib/action_cable/subscription_adapter/reverb.rb` is an Action Cable *subscription
  adapter* that publishes over the Pusher HTTP API. Every broadcast — Turbo Streams' `broadcast_*_to`
  and the two direct `ActionCable.server.broadcast` calls — funnels through it, so no call site
  changes. `config/initializers/reverb_cable.rb` selects it when the variables are present, which
  keeps `config/cable.yml` out of the diff.
- **Client:** `app/javascript/lib/reverb/` registers `<turbo-cable-stream-source>` before turbo-rails
  can (turbo-rails guards its own `define`) and hands turbo's `cable.setConsumer` a pusher-js-backed
  consumer, so views and Stimulus controllers are untouched.
- **Channel names:** `private-ac-<base64url(action cable stream name)>` — reversible, so the
  broadcaster and the auth endpoint derive one from the other with no shared state.
- **Authorization:** `POST /reverb/auth` decodes the channel back to its stream and checks it against
  the session (`ReverbAuthorization`, default deny) before signing. `POST /reverb/subscription` names
  the channel; `POST /reverb/perform` carries typing and presence messages client→server.

### Reverb traps found live

1. **Attaching is refused for Rails apps.** `environment:update --websocket-application-id=…` answers
   `422 "Reverb is not available for Rails applications."`, so Cloud injects nothing. The `REVERB_*`
   variables have to be set by hand from `websocket-application:get --show-sensitive`: `REVERB_APP_ID`,
   `REVERB_APP_KEY`, `REVERB_APP_SECRET`, `REVERB_HOST`, `REVERB_PORT`, `REVERB_SCHEME`.
2. **Cloudflare blocks a default Ruby user agent.** The Reverb host sits behind Cloudflare with the
   browser integrity check on; a signed POST as `Ruby` gets Cloudflare 403 (error 1010) before Reverb
   sees it. `ReverbClient::USER_AGENT` exists for that.
3. **A new WebSocket application is created with `allowedOrigins: []`**, which Reverb reads as "deny",
   so every browser gets `pusher:error 4009 Origin not allowed` — after a clean `101` handshake, so it
   only shows up in the frames. `websocket-application:create --allowed-origins="*"`; `:update` has no
   flag for it.
4. **`maxMessageSize` is 10,000 bytes and no CLI flag raises it.** Reverb answers `413 Payload too
   large` to a bigger HTTP API body. A Campfire message append is **11,436 bytes** (the partial carries
   the boost UI and the actions menu), so messages were dropped while 12-byte typing and unread events
   arrived. The adapter deflates anything near the budget (11,436 → 2,051 bytes) and the browser
   inflates with `DecompressionStream`.
5. **pusher-js needs a `cluster`** even when `wsHost` is set, or it throws
   `Options object must provide a cluster`.

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

## Upstream PRs carried

Patches taken from open `basecamp/once-campfire` pull requests, cherry-picked onto this branch with
`git cherry-pick -x` so each commit records the upstream SHA it came from. When one of these is merged
upstream, drop the local commit on the next `git merge upstream/main`.

### PR #187 — "Serve avatar and logo variants through Active Storage"

<https://github.com/basecamp/once-campfire/pull/187> (OPEN; head `0a1d24d3966cd24a34085c86ea8df9901c8487ba`).

Fixes a 500 on avatar and logo thumbnails when Active Storage is backed by a pathless service. Both
controllers called `ActiveStorage::Blob.service.path_for(variant.key)`, which only `DiskService`
implements; on Cloud's S3-compatible bucket it raises `NoMethodError`. They now stream the processed
representation with `send_blob_stream`. **This is the fix for the variant 500 this fork hit live.**

Commits taken: `495051b8` (`Fix S3-backed avatar and logo rendering`), `388b3c7d`
(`Add regression tests for pathless Active Storage services`). The PR's third commit,
`0a1d24d3` (`Inline avatar variant streaming`), was **skipped as already carried** — it only inlines a
`send_webp_blob` helper that never existed here, because the conflict resolution below wrote the
inlined form directly.

Conflicts resolved, minimally: PR #187 branched from `3fada3d9`, before upstream moved the variant
definitions into the models (`Account#logo_variant`, `User#avatar_variant`). The PR's own
`SQUARE_WEBP_VARIANT` / `logo_variant` controller constants were therefore **not** taken; the current
upstream model helpers are kept and only the send call changed. `test/test_helper.rb` and
`test/controllers/users/avatars_controller_test.rb` were additive conflicts — both sides kept.

Upstream files edited by this PR:

- `app/controllers/accounts/logos_controller.rb`: `send_blob_stream logo_variant` instead of
  `send_png_file ActiveStorage::Blob.service.path_for(...)`.
- `app/controllers/users/avatars_controller.rb`: same, and the `send_webp_blob_file` helper is gone.
- `test/controllers/accounts/logos_controller_test.rb`, `test/controllers/users/avatars_controller_test.rb`:
  one regression test each, driven through a pathless service.
- `test/test_helper.rb`: include `ActiveStorageServiceTestHelper`.

New file (no upstream counterpart): `test/test_helpers/active_storage_service_test_helper.rb` —
`PathlessActiveStorageTestService`, a delegating service with no `path_for`, plus
`with_pathless_active_storage_service`.

### PR #212 — "Require authentication for ActiveStorage direct-upload write endpoints" — NOT carried

<https://github.com/basecamp/once-campfire/pull/212> (OPEN; head `0141eae0`). **Deliberately not taken.**

Upstream already merged an equivalent fix, **#267** (`79eb9a5516a8e0b68ea49961ff3e9d38cd48b59d`,
2026-08-30), which this fork inherits through `upstream/main`:
`app/controllers/concerns/active_storage_authentication.rb` +
`config/initializers/active_storage_authentication.rb` gate `DirectUploadsController#create` and
`DiskController#update` behind a Campfire session cookie (401 for anonymous callers) while leaving
`DiskController#show` public. `test/controllers/active_storage_authentication_test.rb` covers all four
cases.

#212 was cherry-picked, measured and reverted: stacked on top of #267 its `before_action` never fires
first, so it adds no coverage, and it edits `config/initializers/active_storage.rb` — a new upstream-file
conflict surface for nothing. Ed's call, 2026-09-28.

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
- `app/controllers/accounts/logos_controller.rb`, `app/controllers/users/avatars_controller.rb`,
  `test/controllers/accounts/logos_controller_test.rb`, `test/controllers/users/avatars_controller_test.rb`,
  `test/test_helper.rb`: upstream PR #187, above.

### New files (no upstream counterpart, no merge risk)

- `config/initializers/action_cable_redis.rb`: drop `:id` from the Action Cable Redis connector (#3).
- `.cloud/config.json`: experiment-specific Cloud binding.
- `test/test_helpers/active_storage_service_test_helper.rb`: pathless Active Storage service for PR #187's tests.
