# Troubleshooting

Common issues and their resolutions.

### `groups: cannot find name for group ID NNN`
Harmless warning on first start — `entrypoint.sh` suppresses it by registering the docker group. If it persists, rebuild the image:
```bash
docker build -t llm-sandbox:latest .
```

### `gh: HTTP 401`
The host `gh` token was not forwarded. Check that `gh auth status` works on your host machine. The token is read at sandbox startup via `gh auth token`.

### `git commit` fails with signing error
Verify `~/.ssh/id_rsa.pub` (or whatever `user.signingkey` points to) exists on the host. The path must be the literal value in `.gitconfig` — the container mounts `~/.ssh` at that exact path.

### Host service not reachable from sandbox
On Linux, `--network host` means `localhost` inside the container is the host. Confirm the service is actually listening on the host:
```bash
ss -tlnp | grep <port>
```
*Note: On macOS/Windows, `--network host` does not work with Docker Desktop — you must use `host.docker.internal` instead of `localhost`.*

### `psql` connects but `pg_isready -h localhost` fails
`pg_isready` without `-h` uses the Unix socket by default. Specify `-h localhost` to force TCP, which is what `--network host` provides.