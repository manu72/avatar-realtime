# Deploying Sakura to Railway

Step-by-step guide for deploying the Sakura web app to [Railway](https://railway.com)
from GitHub. No prior Railway experience assumed.

Railway builds the app automatically from `requirements.txt` (via its Railpack
builder) and uses the settings in [`railway.json`](railway.json) — start command,
health check, restart policy. You do not need Docker or a Procfile.

## 1. Create a Railway account

1. Go to <https://railway.com> and click **Login**.
2. Choose **Login with GitHub** (simplest, since you'll deploy from GitHub anyway)
   and authorize Railway.
3. New accounts start on a trial; add a payment method under **Account → Billing**
   for the Hobby plan (~$5/month) so deployments keep running.

## 2. Connect GitHub

If you logged in with GitHub, most of this is already done.

1. In the Railway dashboard, open **Account Settings → Integrations** (or you'll
   be prompted the first time you deploy a repo).
2. Click **Configure GitHub App** and grant Railway access to the repository
   (you can restrict access to just this one repo).

## 3. Create a new project

1. From the dashboard, click **+ New → Deploy from GitHub repo**.

## 4. Select the repository

1. Pick the `avatar-realtime` repository from the list.
2. Railway creates a project with one service and immediately starts a first
   build. **That first deploy will fail its health check** — the API key isn't
   set yet. That's expected; continue to the next step.

## 5. Configure environment variables

1. Click the service, then open the **Variables** tab.
2. Add:

   | Variable | Value | Required |
   |---|---|---|
   | `GEMINI_API_KEY` | your Gemini API key from <https://aistudio.google.com/apikey> | **yes** |
   | `SAKURA_DATA_DIR` | `/data` (see volume note below) | recommended |
   | `LOG_LEVEL` | `INFO` (default) or `DEBUG` | no |
   | `ALLOWED_ORIGINS` | extra allowed browser origins, comma-separated (same-origin is always allowed, so usually leave unset) | no |
   | `SITE_URL` | public origin used in Open Graph / Twitter / canonical tags (e.g. `https://your-app.up.railway.app`); if unset, derived from the request Host | recommended for link previews |

   Railway sets `PORT` automatically — do not set it yourself. `HOST` defaults
   to `0.0.0.0`, which is what Railway needs.

3. **Volume (recommended):** SQLite lives on the container filesystem, which is
   wiped on every deploy. To keep user memory across deploys, right-click the
   service → **Attach Volume**, set the mount path to `/data`, and set
   `SAKURA_DATA_DIR=/data` as above. Without a volume the app still works, but
   Sakura forgets everyone on each redeploy.

## 6. First deployment

1. After saving variables, Railway redeploys automatically (or click
   **Deploy → Redeploy**).
2. Watch the build in the **Deployments** tab. A successful deploy shows the
   health check passing (`/health` returning 200) and status **Active**.

## 7. Viewing logs

1. Open the service → **Deployments** tab → click the active deployment.
2. **Build Logs** shows dependency installation; **Deploy Logs** shows the
   running server (startup line, warnings, errors).
3. Logs are also available project-wide under **Observability**.

## 8. Restarting deployments

- Service → **Deployments** → `⋮` menu on the active deployment → **Restart**.
- **Redeploy** rebuilds from the same commit; **Restart** just restarts the
  process. The server shuts down gracefully (closes WebSockets, flushes
  pending memory writes) on both.

## 9. Updating from GitHub

Push to the connected branch (`main` by default):

```bash
git push origin main
```

Railway detects the push, builds, health-checks the new deployment, and swaps
it in. You can change the watched branch under service **Settings → Source**.

## 10. Locating the public URL

1. Service → **Settings** tab → **Networking** section.
2. Click **Generate Domain** to get a public `*.up.railway.app` URL.
3. Open it in a browser — you should see Sakura. (Custom domains can also be
   added in the same section.)

## 11. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Deploy fails health check, logs say `GEMINI_API_KEY is not set` | Add the variable (step 5) and redeploy. |
| `/health` returns 503 `"degraded"` | Same as above — check which field is `false` in the JSON response. |
| Build succeeds but app unreachable | Generate a public domain (step 10). Also confirm you did not set `PORT` or `HOST` manually. |
| Voice chat connects then immediately drops | Check Deploy Logs for `live session failed` — usually an invalid/quota-exceeded Gemini key, or the Live model name has been retired (update `MODEL` in `server.py`). |
| Browser console shows WebSocket 403 | Origin rejected. You're likely loading the app from a different domain than it's served on; add that origin to `ALLOWED_ORIGINS` (e.g. `https://myapp.example.com`). |
| Sakura forgets everyone after each deploy | No volume attached — see step 5. |
| `database is locked` errors | Two replicas sharing one volume. Keep the service at **1 replica** (SQLite is single-writer). |
| Build picks the wrong Python | Version comes from `.python-version` (3.12). Edit that file if needed. |
