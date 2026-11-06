# ssh-deploy-rollback

A GitHub Action that copies your build to a server over SSH, restarts it, checks that it is healthy, and puts the previous build back if it is not.

Made for the common setup of one app on one server (EC2, a VPS, a home box) run by systemd. No agent on the server, no Docker, no extra actions. It uses the `ssh` client that the runner already has.

```yaml
- uses: kimjungminn24/ssh-deploy-rollback@v1
  with:
    host: ${{ secrets.SERVER_HOST }}
    user: ubuntu
    key: ${{ secrets.SERVER_SSH_KEY }}
    known-hosts: ${{ secrets.SERVER_KNOWN_HOSTS }}
    artifact: build/libs/app.jar
    target: /home/ubuntu/app/app.jar
    service: my-app
    health-url: http://localhost:8080/actuator/health
    health-expect: UP
```

## What it does

1. Uploads `artifact` next to `target` on the server.
2. Copies the current build to `target.prev`, so there is something to go back to.
3. Swaps the new build in with a rename, which is a single step on the same disk.
4. Restarts the app, by default with `sudo systemctl restart <service>`.
5. Polls `health-url` from the server until it answers, or until `health-timeout` runs out.
6. If the app never becomes healthy, it prints the last service logs, restores `target.prev`, restarts again and fails the job. You find out from a red check, not from your users.

The health check runs on the server, so `localhost` URLs work and the port does not need to be open to the internet.

## Inputs

| Input | Required | Default | What it is |
|---|---|---|---|
| `host` | yes | | Server address |
| `user` | yes | | SSH user |
| `key` | yes | | Private SSH key. Keep it in a secret |
| `port` | | `22` | SSH port |
| `known-hosts` | | | The server's `known_hosts` line. Recommended, see below |
| `artifact` | yes | | Local file to deploy |
| `target` | yes | | Path of that file on the server |
| `service` | | | systemd service name, used for the default restart and logs commands |
| `restart` | | `sudo systemctl restart <service>` | Any command that restarts the app |
| `logs` | | `sudo journalctl -u <service> -n 80 --no-pager` | Shown when the health check fails |
| `health-url` | yes | | Checked from the server with `curl` |
| `health-expect` | | | Text the response must contain, for example `UP`. Empty means any 2xx passes |
| `health-timeout` | | `60` | Seconds to wait for a healthy answer |
| `health-interval` | | `2` | Seconds between checks |
| `keep` | | `1` | How many previous builds to keep (`app.jar.prev`, `app.jar.prev.2`, ...) |

## Output

`result` is one of:

| Value | Meaning | Job |
|---|---|---|
| `deployed` | The new build is up and healthy | passes |
| `rolled-back` | The new build failed; the previous one is running again | fails |
| `rollback-failed` | The previous build did not come up either | fails |
| `failed-no-backup` | The new build failed and there was nothing to roll back to | fails |

## Setting up the server

**A systemd service**, for example `/etc/systemd/system/my-app.service`:

```ini
[Unit]
Description=my app
After=network-online.target
Wants=network-online.target

[Service]
User=ubuntu
WorkingDirectory=/home/ubuntu/app
EnvironmentFile=/etc/my-app/app.env
ExecStart=/usr/bin/java -jar /home/ubuntu/app/app.jar
SuccessExitStatus=143
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

`SuccessExitStatus=143` tells systemd that a JVM stopped by SIGTERM exited cleanly.

**Let the deploy user restart only that service without a password.** Run `sudo visudo -f /etc/sudoers.d/my-app` and add:

```
ubuntu ALL=(root) NOPASSWD: /usr/bin/systemctl restart my-app, /usr/bin/journalctl -u my-app *
```

**`curl`** must be installed on the server. It is on most images.

## known-hosts

Without `known-hosts` the action asks the server for its host key on every run and trusts the answer, which leaves you open to someone sitting between the runner and the server. To pin it, run this once from a machine you trust and save the output as a secret:

```bash
ssh-keyscan -p 22 your.server.address
```

## Keeping secrets out of the workflow

Put the app's own secrets in a file on the server (`EnvironmentFile=` above) instead of writing them out from the workflow. The workflow then only needs SSH access.

## License

MIT
