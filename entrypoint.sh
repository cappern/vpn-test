#!/bin/sh
# -----------------------------------------------------------------------------
# Synthetic VPN login probe for Cisco AnyConnect (openconnect) with Expect.
# - Declares success ONLY on explicit success tokens.
# - Handles client cert prompts (PEM/P12/PKCS#11).
# - Detects auth loops and bails.
# - Firepower/ASA 'Certificate Validation Failure' caught EARLY via expect_before.
# - Distinguishes client-cert MISSING vs INVALID based on CLIENT_CERT presence.
# - Sleeps FAIL_RETRY_DELAY after any failure.
# - QUIET=1 hides openconnect/expect chatter (only JSON + INFO lines).
# -----------------------------------------------------------------------------
set -eu

VPN_URL="${VPN_URL:?Missing VPN_URL}"
VPN_USER="${VPN_USER:?Missing VPN_USER}"
VPN_PASS="${VPN_PASS:?Missing VPN_PASS}"

MFA_MODE="${MFA_MODE:-password}"
AUTHGROUP="${AUTHGROUP:-}"
EXPECT_TIMEOUT="${EXPECT_TIMEOUT:-30}"
SERVERCERT_PIN="${SERVERCERT_PIN:-}"
CA_CERT_BUNDLE="${CA_CERT_BUNDLE:-}"
SLEEP_INTERVAL="${SLEEP_INTERVAL:-60}"
FAIL_RETRY_DELAY="${FAIL_RETRY_DELAY:-0}"
LOG_PREFIX="${LOG_PREFIX:-[VPN-PROBE]}"
MAX_PROMPTS="${MAX_PROMPTS:-3}"
QUIET="${QUIET:-0}"
DEBUG="${DEBUG:-0}"

CLIENT_CERT="${CLIENT_CERT:-}"
CLIENT_KEY="${CLIENT_KEY:-}"
KEY_PASSWORD="${KEY_PASSWORD:-}"
PKCS11_PIN="${PKCS11_PIN:-}"
MCA_CERTIFICATE="${MCA_CERTIFICATE:-}"
MCA_KEY="${MCA_KEY:-}"
MCA_KEY_PASSWORD="${MCA_KEY_PASSWORD:-}"
CERT_EXPIRE_WARNING="${CERT_EXPIRE_WARNING:-}"
OPENCONNECT_EXTRA="${OPENCONNECT_EXTRA:-}"

OC_ARGS="--protocol=anyconnect --timestamp"
[ -n "$AUTHGROUP" ]        && OC_ARGS="$OC_ARGS --authgroup $AUTHGROUP"
[ -n "$SERVERCERT_PIN" ]   && OC_ARGS="$OC_ARGS --servercert $SERVERCERT_PIN"
[ -n "$CA_CERT_BUNDLE" ]   && OC_ARGS="$OC_ARGS --cafile $CA_CERT_BUNDLE"
[ -n "$CLIENT_CERT" ]      && OC_ARGS="$OC_ARGS --certificate $CLIENT_CERT"
[ -n "$CLIENT_KEY" ]       && OC_ARGS="$OC_ARGS --sslkey $CLIENT_KEY"
[ -n "$KEY_PASSWORD" ]     && OC_ARGS="$OC_ARGS --key-password $KEY_PASSWORD"
[ -n "$MCA_CERTIFICATE" ]  && OC_ARGS="$OC_ARGS --mca-certificate $MCA_CERTIFICATE"
[ -n "$MCA_KEY" ]          && OC_ARGS="$OC_ARGS --mca-key $MCA_KEY"
[ -n "$MCA_KEY_PASSWORD" ] && OC_ARGS="$OC_ARGS --mca-key-password $MCA_KEY_PASSWORD"
[ -n "$CERT_EXPIRE_WARNING" ] && OC_ARGS="$OC_ARGS --cert-expire-warning $CERT_EXPIRE_WARNING"
[ -n "$OPENCONNECT_EXTRA" ] && OC_ARGS="$OC_ARGS $OPENCONNECT_EXTRA"

if [ "${ALLOW_INSECURE:-}" = "1" ]; then
  echo "$LOG_PREFIX [WARN] ALLOW_INSECURE is set, but --no-cert-check was removed in modern openconnect."
  echo "$LOG_PREFIX [WARN] Use SERVERCERT_PIN or CA_CERT_BUNDLE instead."
fi

command -v openconnect >/dev/null 2>&1 || { echo "$LOG_PREFIX [ERROR] openconnect not found in PATH"; exit 127; }
command -v expect       >/dev/null 2>&1 || { echo "$LOG_PREFIX [ERROR] expect not found in PATH"; exit 127; }

EXP_SCRIPT="$(mktemp -t oc_expect.XXXXXX)"
cleanup() { rm -f "$EXP_SCRIPT"; }
trap cleanup EXIT INT TERM HUP

cat >"$EXP_SCRIPT" <<'EOF'
#!/usr/bin/expect -f
# Exit codes:
#   0: success (explicit success tokens observed)
#   1: generic failure (EOF without success tokens)
#   2: servercert pin mismatch / cert verify fail prior to portal
#   3: timeout
#   4: key password required
#   5: PKCS#11 PIN required
#   6: auth loop detected
#   7: client certificate missing (gateway demanded one)
#   8: client certificate invalid/rejected (present but rejected)
#   9: username/password authentication failed

set timeout $env(EXPECT_TIMEOUT)
if {[info exists env(DEBUG)] && $env(DEBUG) ne "" && $env(DEBUG) != "0"} { exp_internal 1 }
if {[info exists env(QUIET)] && $env(QUIET) ne "" && $env(QUIET) != "0"} { log_user 0 } else { log_user 1 }

set success 0
set user_prompts 0
set pass_prompts 0
set creds_banner 0
set max_prompts $env(MAX_PROMPTS)
match_max 65535

# Did caller provide a client cert?
set cert_present 0
if {[info exists env(CLIENT_CERT)] && $env(CLIENT_CERT) ne ""} { set cert_present 1 }

# Launch openconnect
set oc_args $env(OC_ARGS)
eval spawn openconnect $oc_args $env(VPN_URL)

# -------- Global early traps (preempt everything) --------
# Pin mismatch / TLS cert verify failure (pre-portal)
expect_before -re -nocase {none of the .* fingerprint\(s\) specified via --servercert match} { exit 2 }

# Firepower/ASA variants that appear before Username:/Password:
expect_before -re -nocase {certificate[ \t]+validation[ \t]+failure} {
  if {$cert_present} { exit 8 } else { exit 7 }
}
expect_before -re -nocase {please enter your username and password\.} {
  if {$cert_present} { exit 8 } else { exit 7 }
}

# Server explicitly asks for client cert
expect_before -re -nocase {(server requested.*client certificate|certificate requested by server)} {
  if {!$cert_present} { exit 7 }
}

# ---------------------- Main event loop ------------------
while {1} {
  expect {
    -re -nocase "(enter (pem|pkcs.?12).*pass ?phrase:|enter pass phrase for .*key)" {
      if {[info exists env(KEY_PASSWORD)] && $env(KEY_PASSWORD) ne ""} {
        send -- "$env(KEY_PASSWORD)\r"
      } else {
        exit 4
      }
      exp_continue
    }
    -re -nocase "(pkcs#?11|token).*(pin|password):" {
      if {[info exists env(PKCS11_PIN)] && $env(PKCS11_PIN) ne ""} {
        send -- "$env(PKCS11_PIN)\r"
      } else {
        exit 5
      }
      exp_continue
    }
    -re -nocase {(^|\r|\n)[[:space:]]*(username|user name|login)[[:space:]]*:} {
      incr user_prompts
      if {$user_prompts > $max_prompts} { exit 6 }
      send -- "$env(VPN_USER)\r"
      exp_continue
    }
    -re -nocase {(^|\r|\n)[[:space:]]*(password|passcode)[[:space:]]*:} {
      incr pass_prompts
      if {$pass_prompts > $max_prompts} { exit 6 }
      send -- "$env(VPN_PASS)\r"
      exp_continue
    }
    -re -nocase "(login failed|authentication failed|invalid credentials)" {
      exit 9
    }
    -re -nocase "(connected as|cstp connected|established dtls connection|esp .* established)" {
      set success 1
      break
    }
    -re {Got CONNECT response:\s*HTTP/1\.1 200} {
      set success 1
      break
    }
    -re -nocase {please enter your username and password\.} {
      incr creds_banner
      if {$creds_banner > $max_prompts} { exit 6 }
      exp_continue
    }
    timeout {
      exit 3
    }
    eof {
      if {$success} { exit 0 } else { exit 1 }
    }
  }
}
# If we broke out due to success pattern, exit 0
exit 0
EOF
chmod +x "$EXP_SCRIPT"

export OC_ARGS VPN_URL VPN_USER VPN_PASS EXPECT_TIMEOUT KEY_PASSWORD PKCS11_PIN MAX_PROMPTS QUIET CLIENT_CERT DEBUG

iso_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
echo "$LOG_PREFIX [INFO] Effective FAIL_RETRY_DELAY=${FAIL_RETRY_DELAY} MAX_PROMPTS=${MAX_PROMPTS} QUIET=${QUIET} CLIENT_CERT_PRESENT=$([ -n "$CLIENT_CERT" ] && echo 1 || echo 0)"

while :; do
  START="$(date +%s)"
  echo "$LOG_PREFIX [INFO] $(iso_now) Running synthetic VPN login probe..."

  rc=0
  if "$EXP_SCRIPT"; then
    rc=0
  else
    rc=$?
  fi

  END="$(date +%s)"
  DURATION=$((END - START))
  client_cert_label="$([ -n "$CLIENT_CERT" ] && echo present || echo absent)"

  case "$rc" in
    0)
      echo "$LOG_PREFIX [RESULT] {\"status\":\"ok\",\"vpn_url\":\"$VPN_URL\",\"user\":\"$VPN_USER\",\"mfa_mode\":\"$MFA_MODE\",\"duration_s\":$DURATION,\"ts\":\"$(iso_now)\",\"client_cert\":\"$client_cert_label\"}"
      echo "$LOG_PREFIX [INFO] Sleeping ${SLEEP_INTERVAL}s before next probe..."
      sleep "$SLEEP_INTERVAL"
      ;;
    2) reason="cert_validation_failure_or_pin_mismatch" ;;
    3) reason="timeout" ;;
    4) reason="key_password_required" ;;
    5) reason="pkcs11_pin_required" ;;
    6) reason="auth_loop_detected" ;;
    7) reason="client_cert_missing" ;;
    8) reason="client_cert_invalid" ;;
    9) reason="auth_failed" ;;
    *) reason="auth_or_server_error" ;;
  esac

  if [ "$rc" -ne 0 ]; then
    echo "$LOG_PREFIX [RESULT] {\"status\":\"fail\",\"reason\":\"$reason\",\"vpn_url\":\"$VPN_URL\",\"user\":\"$VPN_USER\",\"mfa_mode\":\"$MFA_MODE\",\"duration_s\":$DURATION,\"ts\":\"$(iso_now)\",\"client_cert\":\"$client_cert_label\"}"
    case "$FAIL_RETRY_DELAY" in
      ''|*[!0-9]*)
        echo "$LOG_PREFIX [INFO] Failure; retrying immediately (FAIL_RETRY_DELAY not numeric: '$FAIL_RETRY_DELAY')..."
        ;;
      0)
        echo "$LOG_PREFIX [INFO] Failure; retrying immediately..."
        ;;
      *)
        echo "$LOG_PREFIX [INFO] Failure; retrying in ${FAIL_RETRY_DELAY}s..."
        sleep "$FAIL_RETRY_DELAY"
        ;;
    esac
  fi
done
