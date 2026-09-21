# FreshRSS extensions

Bind-mounted into the FreshRSS container at `/var/www/FreshRSS/extensions`.

Mounting this as a directory (rather than a named volume) means extension installs
are **reproducible**: re-create the stack from scratch and, after re-running
`scripts/install-youlag.sh`, you are back where you were. A named volume would
survive `docker compose down -v` and silently hold stale extensions.

## Nothing here is committed

Everything in this directory is ignored by `.gitignore` except this file and
`.gitkeep`. Third-party extensions are GPL-3.0 code that you are installing, not
authoring — vendoring them into this repository would add a licence obligation
for no benefit. `scripts/install-youlag.sh` fetches them.

Two upstream requirements worth knowing before you file a bug:

- **Server-side caching is off upstream.** FreshRSS explicitly states that
  extensions are cached, so after enabling Youlag you must hard-reload the browser
  to pick up its assets.
- **Enable, do not just install.** Dropping the folder in does nothing until it is
  switched on under *Settings → Extensions*.

## Installing Youlag

```bash
./scripts/install-youlag.sh
```

Then: FreshRSS → *Settings* → *Extensions* → enable **Youlag** → hard-reload.

Requires FreshRSS **1.30.0 or newer**. Pinning `freshrss/freshrss:latest` satisfies
this; pinning an older tag does not.
