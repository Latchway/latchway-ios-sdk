# Firebase Auth

Firebase remains an application dependency. Configure public provider metadata
with `suppliedIdentity: try .firebaseProject(projectID:)`, then pass an existing
token or one-shot async producer to `app.signIn`/`app.restore`. Report later
same-account tokens through `account.updateIdToken` and normal sign-out through
`account.logout`. The optional token-reader helper does not register an auth
authority or add Firebase to the SDK dependency graph. Never cache/log the
returned token or put it in static configuration.
