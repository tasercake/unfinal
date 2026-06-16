# Synopticon Live Editor

Minimal Phoenix LiveView in-memory editor.

## Run

```bash
mix deps.get
mix phx.server
```

Open <http://localhost:3000/>.

Hardcoded password: `synopticon`

## Behavior

- `/` renders one full-page textarea and a bottom password login form.
- Anonymous tabs can type locally, but their edits are not sent to or persisted by the server.
- Login posts to `/login`, sets the Phoenix session cookie for that browser session, and redirects back to `/`.
- Authenticated tabs persist textarea changes into `Synopticon.ContentStore`, a supervised in-memory GenServer.
- `Synopticon.ContentStore` broadcasts each authenticated edit over Phoenix PubSub to all open LiveView tabs.
- No database is used. Server restart clears content.
