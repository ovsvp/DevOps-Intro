# Render service configuration

The QuickNotes free web service on Render, as configured. Nothing here is a secret: the deploy
hook lives in the `RENDER_DEPLOY_HOOK` GitHub Actions secret and is never written to the repo.

| Setting | Value |
|---|---|
| Service type | Web Service |
| Instance type | **Free** (the create form pre-selects a paid plan — it has to be changed) |
| Source | **Existing Image**: `ghcr.io/ovsvp/devops-intro/quicknotes:v0.1.0` |
| Health check path | `/health` |
| Public URL | `https://quicknotes-v0-1-0-zyuh.onrender.com` |

## Environment variables

| Key | Value | Why |
|---|---|---|
| `PORT` | `8080` | Render routes to whatever port this names, default `10000`. |
| `ADDR` | `:8080` | What QuickNotes binds. Set alongside `PORT` so the two agree on the first boot and Render never has to detect a different port and restart the deploy. |
| `DATA_PATH` | `/data/notes.json` | The container runs as UID 65532 and `/app` is root-owned, so the default relative path (`data/notes.json` → `/app/data`) is not writable. The image ships `/data` owned by 65532 for exactly this. |
| `SEED_PATH` | `/app/seed.json` | Where the Lab 6 Dockerfile puts the seed file. Without it `/notes` silently returns `[]`. |

## Why "Existing Image" rather than letting Render build from the repo

The image is the artifact Lab 9 scanned. Pointing Render at the exact tag CI published means the
thing serving traffic is bit-for-bit the thing that was scanned and pulled — not a rebuild that
could resolve a base image differently. It also keeps the deploy fast, since there is no build
step on Render's side at all.

## Deploying from CI

The Task 1 release workflow calls the service's deploy hook after pushing the image, so a new
`v*` tag both publishes and redeploys. The hook URL is stored as the `RENDER_DEPLOY_HOOK`
Actions secret, and the tag to deploy is passed as a URL-encoded `imgURL` parameter.

## Teardown

Free instance hours cost nothing, so the service can be left running. To remove it:
Render dashboard → the service → **Settings** → **Delete Service**. The deploy hook should also
be regenerated (Settings → Deploy Hook) once the submission is graded, since the URL embeds a key.
