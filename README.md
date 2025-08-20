# VPN Synthetic Login Probe (openconnect + expect)

A tiny Alpine-based container that runs a **synthetic login probe** against a Cisco AnyConnect-compatible VPN gateway using [`openconnect`](https://www.infradead.org/openconnect/) driven by `expect`. It prints a JSON result line for each probe, suitable for log collection and alerting.

> **What this is not:** This container is not meant to **establish and keep** a VPN tunnel for general traffic. It simply verifies that authentication reaches the "connected" stage (or fails) and reports it.

---

## Features

- Minimal Alpine image with `openconnect` + `expect`.
- Hardened certificate options via **server certificate pin** or **custom CA bundle**.
- **Client certificate support**: PEM pair, PKCS#12 (`.p12/.pfx`), or **PKCS#11** (smart card/HSM).
- Optional **multi-certificate authentication** (Cisco MCA: machine + user cert).
- Clear structured output (one JSON line per attempt).
- Fast retry on failure (no sleep by default), sleep between successful probes.
- Proper init (`tini`) for clean signal handling and shutdown.

---

## Image contents

- `openconnect`
- `expect`
- `ca-certificates`
- `curl`, `jq` (handy in shells/debug)
- `oath-toolkit` (optional if you need to generate TOTP externally)
- `tini` (PID 1)

> Note: `bash`, `iproute2`, and `iptables` **are not required** for the probe and are omitted to keep the image small.

---

## Environment variables

| Variable               | Required | Default        | Description |
|------------------------|----------|----------------|-------------|
| `VPN_URL`              | ✅        | —              | VPN portal URL, e.g. `https://vpn.example.com` |
| `VPN_USER`             | ✅        | —              | Username |
| `VPN_PASS`             | ✅        | —              | Password or passcode (per your MFA mode) |
| `MFA_MODE`             | ❌        | `password`     | For logging/metadata only (e.g. `password`, `totp`, `push`) |
| `AUTHGROUP`            | ❌        | *(empty)*      | AnyConnect auth group (if your portal requires one) |
| `EXPECT_TIMEOUT`       | ❌        | `30`           | Seconds to wait for prompts/output in the expect driver |
| `SERVERCERT_PIN`       | ❌        | *(empty)*      | Server certificate pin, e.g. `sha256:ABCD...` |
| `CA_CERT_BUNDLE`       | ❌        | *(empty)*      | Path to a PEM bundle to trust in addition to system CAs |
| `SLEEP_INTERVAL`       | ❌        | `60`           | Delay **after a success** (seconds) before next probe |
| `FAIL_RETRY_DELAY`     | ❌        | `0`            | Delay **after a failure** (seconds) before retry |
| `LOG_PREFIX`           | ❌        | `[VPN-PROBE]`  | Prefix tag for log lines |
| `ALLOW_INSECURE`       | ❌        | *(unset)*      | If set to `1`, only logs a warning (no effect); use pin or CA bundle instead |
| `CLIENT_CERT`          | ❌        | *(empty)*      | Client certificate **path** (PEM/P12) or **PKCS#11 URL** |
| `CLIENT_KEY`           | ❌        | *(empty)*      | Private key path (PEM). Not needed for `.p12` |
| `KEY_PASSWORD`         | ❌        | *(empty)*      | Passphrase/PIN for `CLIENT_CERT`/`CLIENT_KEY` (PEM/P12) |
| `PKCS11_PIN`           | ❌        | *(empty)*      | Token PIN when using PKCS#11 (smart card/HSM) |
| `MCA_CERTIFICATE`      | ❌        | *(empty)*      | Secondary "user" certificate (Cisco MCA) |
| `MCA_KEY`              | ❌        | *(empty)*      | Secondary private key (PEM) |
| `MCA_KEY_PASSWORD`     | ❌        | *(empty)*      | Passphrase for secondary key |
| `CERT_EXPIRE_WARNING`  | ❌        | *(empty)*      | Emit warning when client cert has ≤ this many days left |
| `OPENCONNECT_EXTRA`    | ❌        | *(empty)*      | Extra flags passed verbatim to `openconnect` |

> The entrypoint prints a structured JSON line:
>
> ```json
> {"status":"ok","vpn_url":"https://vpn.example.com","user":"alice","mfa_mode":"password","duration_s":2,"ts":"2025-08-19T06:00:00Z"}
> ```
> or on failure:
> ```json
> {"status":"fail","reason":"auth_or_server_error","vpn_url":"https://vpn.example.com","user":"alice","mfa_mode":"password","duration_s":3,"ts":"2025-08-19T06:00:10Z"}
> ```

---

## Building

```bash
docker build -t vpn-probe:alpine .
```

---

## Running (Docker CLI)

> Even as a probe, some `openconnect` builds attempt to create a TUN device during connect. If yours does not, you can remove `--cap-add`/`--device`.

### 1) Username/Password only

```bash
docker run --rm \
  --cap-add=NET_ADMIN \
  --device /dev/net/tun \
  -e VPN_URL="https://vpn.example.com" \
  -e VPN_USER="alice" \
  -e VPN_PASS="s3cr3t" \
  vpn-probe:alpine
```

### 2) **Client Certificate (PEM pair)**

```bash
docker run --rm \
  --cap-add=NET_ADMIN \
  --device /dev/net/tun \
  -v "$PWD/certs:/certs:ro" \
  -e VPN_URL="https://vpn.example.com" \
  -e VPN_USER="alice" \
  -e VPN_PASS="use-or-blank" \
  -e CLIENT_CERT="/certs/client.crt.pem" \
  -e CLIENT_KEY="/certs/client.key.pem" \
  -e KEY_PASSWORD="your-key-passphrase-if-any" \
  vpn-probe:alpine
```

### 3) **Client Certificate (PKCS#12 .p12/.pfx)**

```bash
docker run --rm \
  --cap-add=NET_ADMIN \
  --device /dev/net/tun \
  -v "$PWD/certs:/certs:ro" \
  -e VPN_URL="https://vpn.example.com" \
  -e VPN_USER="alice" \
  -e VPN_PASS="use-or-blank" \
  -e CLIENT_CERT="/certs/client.p12" \
  -e KEY_PASSWORD="p12-password" \
  vpn-probe:alpine
```

### 4) **PKCS#11 (smart card/HSM)**

```bash
docker run --rm \
  --cap-add=NET_ADMIN \
  --device /dev/net/tun \
  -e VPN_URL="https://vpn.example.com" \
  -e VPN_USER="alice" \
  -e VPN_PASS="use-or-blank" \
  -e CLIENT_CERT="pkcs11:token=MyToken;id=%01" \
  -e PKCS11_PIN="123456" \
  -e OPENCONNECT_EXTRA="--key-password-from-fsid" \
  vpn-probe:alpine
```

> You may need to install PKCS#11 modules in the image and point `p11-kit` to them for smart card support. The base image does not include smart card middleware.

### 5) **Server certificate pin**

```bash
docker run --rm \
  --cap-add=NET_ADMIN \
  --device /dev/net/tun \
  -e VPN_URL="https://vpn.example.com" \
  -e VPN_USER="alice" \
  -e VPN_PASS="s3cr3t" \
  -e SERVERCERT_PIN="sha256:XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" \
  vpn-probe:alpine
```

### 6) **Custom CA bundle**

```bash
docker run --rm \
  --cap-add=NET_ADMIN \
  --device /dev/net/tun \
  -v "$PWD/custom-vpn.pem:/etc/ssl/certs/custom-vpn.pem:ro" \
  -e VPN_URL="https://vpn.example.com" \
  -e VPN_USER="alice" \
  -e VPN_PASS="s3cr3t" \
  -e CA_CERT_BUNDLE="/etc/ssl/certs/custom-vpn.pem" \
  vpn-probe:alpine
```

> **Get a server pin:**  
> ```bash
> openssl s_client -connect vpn.example.com:443 -servername vpn.example.com </dev/null 2>/dev/null \
>   | openssl x509 -noout -fingerprint -sha256
> ```
> Convert the `SHA256 Fingerprint` to `sha256:...` for `SERVERCERT_PIN` (colon-separated hex is fine).

---

## Docker Compose example

```yaml
services:
  vpn-probe:
    image: vpn-probe:alpine
    build: .
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    env_file:
      - .env
    # Mount PEM/KEY or P12 as needed:
    # volumes:
    #   - ./certs/client.crt.pem:/certs/client.crt.pem:ro
    #   - ./certs/client.key.pem:/certs/client.key.pem:ro
    #   - ./certs/client.p12:/certs/client.p12:ro
    #   - ./certs/custom-vpn.pem:/etc/ssl/certs/custom-vpn.pem:ro
    # Optional logging limits
    # logging:
    #   driver: json-file
    #   options:
    #     max-size: 10m
    #     max-file: "3"
```

See `env.example` for variables.

---

## Output & Logging

- Log lines are prefixed with `LOG_PREFIX` (default `[VPN-PROBE]`).
- Each probe emits a single **JSON** result line (either `status":"ok"` or `status":"fail"`).
- Failure `reason` examples: `cert_validation_failure`, `timeout`, `key_password_required`, `pkcs11_pin_required`, `auth_or_server_error`.
- Timestamps are **UTC** ISO-8601.

---

## Health checks

A built-in Docker `HEALTHCHECK` is **not** included, because the probe is periodic and sleeps between runs. If you want a health check, you can:
1. Bind-mount a small directory and have a sidecar read the latest JSON line.
2. Or modify the entrypoint to write the last result to `/health/last.json` and build your own `HEALTHCHECK` that parses it.

---

## Security notes

- Prefer **`SERVERCERT_PIN`** or a **custom CA bundle** over any insecure flags. Modern `openconnect` removed `--no-cert-check`.
- The container runs as `root` by default because `openconnect` often needs elevated privileges for TUN. If you change to `--authenticate`-style flows (not what this entrypoint uses), you may be able to run unprivileged—adjust at your own risk.
- Avoid putting real credentials in Compose files; consider Docker/Kubernetes secrets.

---

## Troubleshooting

- **Stuck at redirect / 303 loop:** Ensure the portal really speaks AnyConnect and that your `AUTHGROUP` is correct.
- **`Certificate Validation Failure`:** Use `SERVERCERT_PIN` or `CA_CERT_BUNDLE`.
- **`key_password_required` / `pkcs11_pin_required`:** Provide `KEY_PASSWORD` or `PKCS11_PIN`.
- **Immediate failure:** Increase `EXPECT_TIMEOUT`. Portals with extra banners or consent pages can be slower.
- **MFA specifics:** If your portal requires a one-time passcode, make sure `VPN_PASS` is already the correct passcode for that attempt. (If needed, generate TOTP externally with `oathtool`.)

---

## License

MIT (or your project’s license).



### Verbosity

- `QUIET` (default `0`): When set to `1`, the container hides openconnect/expect chatter and only prints JSON result lines plus minimal `[INFO]` lines. This is implemented via Expect's `log_user 0`, so internal success detection still works reliably.
