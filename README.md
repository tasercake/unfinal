# Unfinal

Anti-draft public live-writing tool for fighting perfectionism: if text exists, it is already out there.

Each URL is a live document. Visitors can read in real time; configured authenticated writers can edit. All accepted changes are public immediately.

## Built right now

- Elixir/Phoenix LiveView + Phoenix PubSub for live updates.
- Clerk OAuth/OIDC login + writer allowlist from `config/local/writers.txt`.
- One live document per path (`/`, `/notes`, `/foo/bar`, etc.).
- Documents persist in SQLite (source of truth); Litestream provides async backup to S3/R2.
- `.env` auto-load for local env vars.

## Run

```bash
mix deps.get
cp .env.example .env
mix phx.server
```

Open <http://localhost:4000/>.

## Persistence

Documents are stored in a local SQLite database (source of truth). [Litestream](https://litestream.io/)
runs as a sidecar to provide continuous async backup to an S3-compatible replica (e.g. Cloudflare R2).

Required env vars:

```bash
UNFINAL_STORAGE_MODE=sqlite
UNFINAL_DATABASE_PATH=./.data/unfinal.sqlite3
UNFINAL_DATA_DIR=.data
```

Litestream reads S3 replica credentials from the environment for backup/restore only.

## Legacy R2 archive

The original R2 object-store data remains as a **read-only archive**. The normal
web app does **not** read from or write to R2. R2 archive access is available
only through explicit operator tasks:

```bash
# Backfill from archived R2 indexes into SQLite (must pass the explicit flag)
mix unfinal.migrate_r2_to_sqlite --allow-r2-archive-read
```

To enable R2 archive reads for admin tasks, set `UNFINAL_ALLOW_R2_ARCHIVE_READ=true`
in the environment.

## Rollback

Rollback target is the Phase 5 app version with SQLite still primary.
Do **not** switch back to R2-primary without accepting data loss or running a
separate SQLite-to-R2 export first — R2 no longer contains writes made after
the Phase 6 cutover.

## Clerk OAuth/OIDC

Production uses server-side Clerk OAuth/OIDC authorization-code flow. No ClerkJS/React/app auth JavaScript.

Set env vars:

```bash
CLERK_FRONTEND_API_URL=https://<your-clerk-frontend-api>.clerk.accounts.dev
CLERK_OAUTH_CLIENT_ID=...
CLERK_OAUTH_CLIENT_SECRET=...
CLERK_OAUTH_REDIRECT_URI=https://your-domain.example/auth/clerk/callback
CLERK_OAUTH_SCOPES="email profile"
```

In Clerk Dashboard → OAuth applications, create app with redirect URI matching `CLERK_OAUTH_REDIRECT_URI`. Scopes should include `openid email profile`; app adds `openid` automatically.

## Local writers

```bash
mkdir -p config/local
echo you@example.com > config/local/writers.txt
```

One email per line. `config/local/` is git-ignored.

## Deploy on [exe.dev](exe.dev) VM

From the repo directory on the VM:

```bash
./deploy-exe-dev.sh
```
