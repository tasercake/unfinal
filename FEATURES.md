# Features

Unfinal is an anti-draft public live-writing tool for publishing text as soon as it exists.

1. Live document pages let public readers watch text update in real time.
2. Personal namespaces let each claimed user publish their own notebook.
3. User-created public documents live under `/n/...`, with other routes reserved for application and owner use.
4. Nested document URLs let users organize pages inside a namespace.
5. Visitors can read public documents without logging in.
6. Namespace owners can edit only their own claimed namespace.
7. A claim page lets authenticated users reserve one namespace.
8. Namespace sidebars provide a page index for navigating documents.
9. Namespace owners can delete non-root pages.
10. Namespace owners can change non-root page addresses while old addresses keep redirecting.
11. The `/live` page lists documents currently being edited and documents edited recently.
12. Readers receive live document updates without manually refreshing.
13. Each document shows its live public reader count to readers and its writer.
14. Writer presence tracks active editing activity for live documents.
15. Login is powered by Clerk; the current implementation uses Clerk OAuth because the app has no JavaScript frontend framework.
16. Edits are automatically persisted while the writer types.
17. Documents have editable titles shown to readers, in navigation, and in browser metadata.
18. Documents are durably stored in SQLite.
19. Production backups are supported through Litestream to S3/R2-compatible storage.
20. Deployment automation builds assets, runs migrations, validates backup restore, and restarts services.
21. CI checks cover tests, migrations, schema consistency, and deployment readiness.
