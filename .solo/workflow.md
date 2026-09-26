# Workflow — campfire-experiment

**THROWAWAY EXPERIMENT.** A fork of basecamp/once-campfire (git remote `upstream`). The question it
answers: *what is the MINIMUM change that runs Campfire on Laravel Cloud?* We harvest the learnings into
brain (`~/Herd/brain/ideas/2026-09-26-campfire-one-click-on-laravel-cloud.md`). This code is never
promoted to production and never offered to customers.

## Phase & mode
- phase: experiment
- default mode: A-autonomous. **Commit directly to `main`** (no PR ceremony for a throwaway), in small
  commits with clear messages, and push. Ed's call via brain, 2026-09-26.
- Upstream sync: `git fetch upstream && git merge upstream/main`. Our diff from upstream must stay
  MINIMAL. Prefer new files, initializers, and ENV-driven config over editing upstream files. Every
  upstream file we edit is a future merge conflict, so list each one in `CLOUD.md`.

## Hard gate
- command: `bin/rails test` against the SAME database engine the Cloud deploy uses (Postgres once
  ported), plus `bin/rubocop` and `bin/brakeman` on files we touched.
- Local toolchain: the host has only system Ruby 2.6. Use Docker (`/usr/local/bin/docker`,
  `ruby:3.4.10-slim`, or the repo Dockerfile) rather than installing a Ruby manager on Ed's machine.
- CI: `.github/workflows/ci.yml` (brakeman, rubocop, tests on SQLite). Actions on a fork start
  disabled. **Never enable `publish-image.yml`**, which pushes images to ghcr.

## Agent-role constraints
- none. Fleet bindings come from `~/Herd/brain/agents.json`.

## Hard rules for this repo
- Never set a Cloud env var for a Cloud-provisioned resource (the DB, cache, and bucket creds are
  injected). You may set app secrets: SECRET_KEY_BASE, VAPID_*, DISABLE_SSL. Secrets never go on disk or into git.
- `.cloud/config.json` is committed (brain standing policy).
