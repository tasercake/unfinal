# Synopticon Live Editor

Minimal Phoenix LiveView in-memory editor.

## Run

```bash
mix deps.get
cp .env.example .env
mix phx.server
```

Open <http://localhost:3000/>.

Synopticon loads `.env` from the current app directory at startup for optional local environment variables. No password variable is required.

## Login with exe

- Development uses a fake `Login with exe` flow. Clicking `/login` signs in as `dev@example.com` with user id `dev-user-1234`, matching the session shape used by real exe headers.
- Production expects exe.dev's proxy to provide `X-ExeDev-UserID` and `X-ExeDev-Email` after authentication.
- If production `/login` is reached without those headers, Synopticon redirects to `/__exe.dev/login?redirect=/login`.

## Behavior

- `/` renders one full-page textarea and a bottom `Login with exe` link.
- Anonymous tabs can type locally, but their edits are not sent to or persisted by the server.
- Login sets the Phoenix session cookie for that browser session, and redirects back to `/`.
- Authenticated tabs persist textarea changes into `Synopticon.ContentStore`, a supervised in-memory GenServer.
- `Synopticon.ContentStore` broadcasts each authenticated edit over Phoenix PubSub to all open LiveView tabs.
- No database is used. Server restart clears content.

## Deploy on exe.dev VM

Run from the repo directory on the VM:

```bash
./deploy-exe-dev.sh
```

Defaults:

- `SERVICE_NAME=synopticon`
- `APP_DIR=$(pwd -P)`
- `PHX_HOST=$(hostname).exe.xyz`
- `PORT=8000`

Override when needed:

```bash
PHX_HOST=synopticon.exe.xyz PORT=8000 ./deploy-exe-dev.sh
```

The script fetches prod deps, compiles, runs `mix assets.deploy`, writes `/etc/synopticon/synopticon.env` with a persisted `SECRET_KEY_BASE`, writes or updates `/etc/systemd/system/synopticon.service`, enables the service, and restarts it. It prints service status, plus logs if restart fails.
