#!/usr/bin/env python3
"""Print a PostgreSQL SCRAM-SHA-256 verifier for a password held in an env var.

Usage: python3 scripts/scram_verifier.py [ENV_VAR]   (default: GRAFANA_DB_PASSWORD)

The output has the same form psql's backslash-password command sends:
  SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey>
Passing it to ALTER ROLE ... PASSWORD means the plaintext never reaches the
server, so it cannot appear in server logs (log_statement = 'ddl' and the like).
Only ASCII passwords are handled; SASLprep normalisation is skipped on purpose.
"""
import base64
import hashlib
import hmac
import os
import sys

ITERATIONS = 4096   # PostgreSQL's default (scram_iterations)
SALT_LEN = 16       # SCRAM_DEFAULT_SALT_LEN


def scram_verifier(password: str) -> str:
    if not password.isascii():
        sys.exit("password must be ASCII (SASLprep is not implemented here)")
    salt = os.urandom(SALT_LEN)
    salted = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, ITERATIONS, 32)
    client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
    stored_key = hashlib.sha256(client_key).digest()
    server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
    b64 = lambda b: base64.b64encode(b).decode()
    return f"SCRAM-SHA-256${ITERATIONS}:{b64(salt)}${b64(stored_key)}:{b64(server_key)}"


if __name__ == "__main__":
    var = sys.argv[1] if len(sys.argv) > 1 else "GRAFANA_DB_PASSWORD"
    pw = os.environ.get(var)
    if not pw:
        sys.exit(f"{var} is not set")
    print(scram_verifier(pw))
