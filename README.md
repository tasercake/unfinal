# Unfinal

Anti-draft public live-writing tool for fighting perfectionism: if text exists, it is already out there.

Each URL is a live document. Visitors can read in real time; configured authenticated writers can edit. All accepted changes are public immediately.

## Built right now

- Elixir/Phoenix LiveView + Phoenix PubSub for live updates.
- Clerk OAuth/OIDC login + writer allowlist from `config/local/writers.txt`.
- One live document per path (`/`, `/notes`, `/foo/bar`, etc.).
- No database; documents persist as plain-text objects in S3-compatible storage.
- Cloudflare R2-compatible conditional writes prevent stale clobbers.
- `.env` auto-load for local env vars.

## Run

```bash
mix deps.get
cp .env.example .env
mix phx.server
```

Open <http://localhost:4000/>.

## Persistence

Documents are stored in S3-compatible object storage, intended for Cloudflare R2.

Required env vars:

```bash
UNFINAL_S3_BUCKET=...
UNFINAL_S3_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
UNFINAL_S3_ACCESS_KEY_ID=...
UNFINAL_S3_SECRET_ACCESS_KEY=...
UNFINAL_S3_REGION=auto
```

Each document key is `documents/#{sha256(path)}.txt`. Writes use S3 conditional `PUT` (`If-None-Match: *` for create, `If-Match: <etag>` for update) plus `unfinal-revision` metadata. ETags are opaque identity tokens, not ordering values.

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
