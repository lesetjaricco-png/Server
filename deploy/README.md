# Lichess Guard deployment

GitHub publishes `ghcr.io/lesetjaricco-png/server:latest` after a merge. That publication does not deploy anything. The Ubuntu server is the only place that starts a container, and it does so on a short daily window. `latest` is only a candidate. The running container is pinned to an immutable `sha256` digest.

## What runs where

GitHub Actions builds, tests, and publishes the image. None of that is changed by this directory.

On the server:

- `lichess-guard-deploy.timer` starts the deployment service at the decision time.
- `lichess-guard-deploy.service` runs `/usr/local/sbin/lichess-guard-deploy` once.
- That script resolves `latest` once, stores the digest, pulls `image@sha256:...`, and replaces the container only when the digest changed.
- Docker restarts the already pinned container after a reboot. A reboot does not resolve `latest`.

The timer uses `Persistent=false`. If the machine is off for the whole window, that window is skipped.

## Install

On a fresh Ubuntu server, as root, from a checkout of this repository:

```bash
bash deploy/setup-ubuntu.sh
```

The script is safe to run again. It will not overwrite `/etc/lichess-guard/app.env`, `/etc/lichess-guard/deploy.env`, or `/var/lib/lichess-guard/state.json`, and it will not delete containers or images. It does not enable the timer and it does not log in to GHCR.

It installs Docker if the `docker` command is missing, and it enables Docker so the application container can return after a reboot.

## GHCR credential

Create a GitHub token that can only read packages, then on the server:

```bash
docker login ghcr.io
```

Use a username and that read-only token. Do not use `PR_AUTOMATION_TOKEN`, `GITHUB_TOKEN`, a repository write token, or the token that publishes images. The login is stored by Docker for the root user. It is not written into this repository, the unit files, or `deploy.env`.

To rotate it, run `docker logout ghcr.io` and `docker login ghcr.io` again with the new read-only token. The running container keeps its current image until the next successful deployment.

## Application secrets

Edit `/etc/lichess-guard/app.env`. This file stays on the server.

```bash
chmod 600 /etc/lichess-guard/app.env
```

Set `AUTH_SHARED`, `LICHESS_TOKEN`, and any `RECEIVER_*` values the application should use. Empty placeholders are listed in `deploy/app.env.example`. The deployment script passes this file with `--env-file` and then sets `HOST=0.0.0.0` and `PORT` from `CONTAINER_PORT`. Those two values override `HOST` and `PORT` if they are also present in `app.env`.

The deployment logs must never contain this file. Do not paste it into GitHub or into a unit file.

## Deployment window

`/etc/lichess-guard/deploy.env`:

| Name | Default | Meaning |
| --- | --- | --- |
| `DECISION_TIME` | `00:00` | When the window opens, `HH:MM` |
| `WINDOW_MINUTES` | `7` | Length of the window. It must not cross midnight |
| `TIMEZONE` | `UTC` | Timezone used by the script |
| `IMAGE_NAME` | `ghcr.io/lesetjaricco-png/server` | Registry image, without a tag |
| `CONTAINER_NAME` | `lichess-guard` | Production container name |
| `HOST_PORT` | `8080` | Port on the server |
| `CONTAINER_PORT` | `8080` | Port inside the container |
| `HEALTH_URL` | `http://127.0.0.1:8080/health` | Existing `GET /health` endpoint |
| `STARTUP_WAIT` | `30` | Seconds allowed for the process to answer |

The systemd timer uses the server's timezone. Set the server timezone to the same value as `TIMEZONE` (the default is UTC). If they differ, the timer can fire outside the script's window and the script will exit without deploying. That is safe. Do not change the server timezone only to chase a deploy.

After changing `DECISION_TIME`, run `bash deploy/setup-ubuntu.sh` again so the timer's `OnCalendar` matches, then restart the timer if it is already enabled:

```bash
systemctl daemon-reload
systemctl restart lichess-guard-deploy.timer
```

## Activate the timer

Do this only after `docker login`, `app.env`, and `deploy.env` are in place.

```bash
systemctl enable --now lichess-guard-deploy.timer
systemctl list-timers lichess-guard-deploy.timer
```

Enabling the timer does not deploy immediately unless the current time is already inside the window.

## What a window does

At the first run inside a window the script reads `latest` once and stores that digest in `/var/lib/lichess-guard/state.json` as `deployment_target_digest`. Later publishes are ignored until the next window.

If the digest matches the running release, the container is left alone.

If it differs, the new digest is pulled first. A failed pull leaves the current container running. After a successful pull the script stops the old container, starts the new one with `--restart unless-stopped`, and calls `GET /health`.

Health must return HTTP 200 and `"ok": true`. `"ready": true` is not required. The check does not send `X-Auth-Token`.

A failed first deployment removes the new container and stops. There is no previous release to restore, so the server has no application container until the next window.

A failed later deployment restores `previous_digest` once. It does not try any other published image. If that rollback also fails, the script records the error and stops.

## State

`/var/lib/lichess-guard/state.json` is mode `0640` and survives reboot. The script writes a temporary file and renames it into place.

`current_digest` is the last release that passed health. `previous_digest` is the release that will be restored if the next one fails. Neither field is the tag `latest`.

## Logs and the current digest

```bash
journalctl -u lichess-guard-deploy.service -n 100 --no-pager
python3 -m json.tool /var/lib/lichess-guard/state.json
docker inspect -f '{{index .Config.Labels "lichess-guard.digest"}}' lichess-guard
```

The label is the digest the container was started from.

## Manual rollback

Outside a deployment window, restore the stored previous release once:

```bash
/usr/local/sbin/lichess-guard-deploy --rollback
```

This does not read `latest`. It starts `previous_digest` and health-checks it. If `previous_digest` is empty, it exits with an error.

## Troubleshooting

- `step=window result=outside` means the timer ran outside `DECISION_TIME` plus `WINDOW_MINUTES`. No image was pulled.
- `step=lock result=busy` means a deployment is already running.
- `result=pull-failed` means the current container was not stopped.
- `result=rolled-back` means the new digest failed health or startup and the previous digest is running again.
- `result=rollback-failed` or `result=first-deploy-failed` needs an operator. The script will not try another version by itself.
- `missing /etc/lichess-guard/app.env` means the secrets file was not created. The running container is not stopped for that error.
- A container replacement drops the application's in-memory signal and receiver cache. The receiver has to post its state again. That is existing application behavior.

## Local test

`deploy/test-deploy.sh` exercises the script with a fake `docker` command. It does not contact GHCR and it does not start the production container. From the repository root:

```bash
bash deploy/test-deploy.sh
```
