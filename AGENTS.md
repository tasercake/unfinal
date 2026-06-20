# Unfinal

Anti-draft public live-writing tool for fighting perfectionism: if text exists, it is already out there.

## Product

Unfinal is a tiny writing space where each URL is a live document. Visitors can read in real time; authenticated writers can edit, all changes are public in real-time.

## Tech Stack

Elixir/Phoenix LiveView app with Phoenix PubSub, Clerk OAuth/OIDC auth stored in signed session cookies, `.env` config, and S3-compatible object storage for document persistence.

## Development rules

- As of Elixir 1.20, Elixir is a gradually typed language. You *must* use strictly the correct types at all times, and must not ignore type errors reported by compiler or linters.
- Bare javascript is *strongly* discouraged. Use TypeScript instead wherever possible.
- Global CSS styles defined in `.css` files are strongly discouraged. Use tailwind wherever possible.

