# Laravel Cloud

This throwaway fork tests the minimum changes required to run Campfire on Laravel Cloud. Cloud-provisioned resource credentials are never set manually; attaching each resource supplies its managed environment variables.

## Runtime

- Build: `SECRET_KEY_BASE_DUMMY=1 bundle exec rails assets:precompile`
- Deploy: `bin/rails db:prepare`
- Web: `bin/start-app` (Cloud already provides the public web proxy, so the Procfile does not wrap Puma in Thruster)
- Background process: `FORK_PER_JOB=false INTERVAL=0.1 bundle exec resque-pool`
- App variables: `DISABLE_SSL=true`, `SKIP_TELEMETRY=true`, `VAPID_PUBLIC_KEY`, and `VAPID_PRIVATE_KEY`

## Cloud Resources

The production environment requires an attached Postgres database, Valkey cache, and private object-storage bucket. Do not add database, cache, or bucket variables in the Cloud dashboard because attached resources inject them separately.

The exact injected variable names and CLI-versus-dashboard setup steps will be recorded here after the live deployment is inspected.

## Upstream Files Edited

- `Gemfile`: replace SQLite with PostgreSQL and add the S3 SDK.
- `config/database.yml`: configure PostgreSQL from Cloud-injected variables.
- `config/storage.yml`: add an S3 service using Cloud-injected variables.
- `config/environments/production.rb`: select the S3 service in production.
- `db/migrate/20231215043540_create_initial_schema.rb`: replace SQLite FTS5 with a PostgreSQL full-text index table.
- `db/migrate/20251126115722_change_active_to_status_on_users.rb`: use a portable boolean literal during migration.
- `db/schema.rb`: regenerated from PostgreSQL so fresh test databases match production.
- `app/models/message/searchable.rb`: query and maintain the PostgreSQL search index.
- `app/models/user.rb`: keep autocomplete matching case-insensitive on PostgreSQL.
- `Gemfile.lock`: lock the PostgreSQL and S3 driver dependencies.
- `Procfile`: avoid nesting Thruster behind Cloud's own web proxy.

`.cloud/config.json` is experiment-specific and has no upstream counterpart.
