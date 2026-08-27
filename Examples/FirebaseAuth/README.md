# Firebase Auth

The adapter takes an async operation, keeping Firebase out of the core target
and leaving account selection with the application. Never cache or log the
returned Firebase ID token in adapter code.
