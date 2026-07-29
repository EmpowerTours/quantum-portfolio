"""Passphrase-sealed keystore for the agent's signing identity.

Why this exists
---------------
On 2026-07-12 the ML-DSA key that signed the shipped mainnet provenance trail
was lost. It was never backed up, `keys/` is gitignored, and
`pq_signing.ensure_keypair` silently generated a replacement identity rather
than failing, so nothing surfaced the loss until the zkVM guest was changed to
commit the signing key's fingerprint two weeks later.

Two defences followed. `ensure_keypair` now refuses to create an identity
unless asked explicitly (`pq_signing.MissingKeypair`), and this module gives
the identity somewhere durable to live.

Design
------
* **scrypt** (n=2**20, r=8, p=1) stretches the passphrase. Memory-hard, so an
  offline attacker with the sealed file cannot cheaply brute-force it on GPUs.
  ~5s per attempt on this machine — deliberately slow, since the key is
  unsealed rarely.
* **ChaCha20-Poly1305** encrypts the three secret keys under the derived key.
* **The public half stays in cleartext**, and the whole cleartext header is
  passed as AEAD associated data. So you can read *which identity* a sealed
  file holds without the passphrase — which is exactly the check that was
  missing in July — while any edit to that header makes decryption fail.
* Nothing derived from the passphrase touches disk, and the passphrase is read
  from the environment or an interactive prompt, never from argv (visible in
  `ps`) and never logged.

Usage
-----
    # seal the current identity (prompts for a passphrase)
    python -m src.keystore seal keys/ agent-identity.age.json

    # show which identity a sealed file holds — no passphrase needed
    python -m src.keystore identity agent-identity.age.json

    # restore into a keys directory
    python -m src.keystore open agent-identity.age.json keys/

Store the sealed file somewhere durable and off this machine: a password
manager entry, an encrypted backup, or offline media. It is useless without
the passphrase, so it is safe to keep alongside ordinary backups — but the
passphrase must NOT live in the same place.
"""
from __future__ import annotations

import base64
import getpass
import hashlib
import json
import os
import stat
import sys
from pathlib import Path
from typing import Any

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

KEYSTORE_VERSION = 1
SCRYPT_N = 2 ** 20      # ~1 GiB, ~5 s per guess
SCRYPT_R = 8
SCRYPT_P = 1
KEY_LEN = 32
NONCE_LEN = 12

PASSPHRASE_ENV = "QUANTUM_KEYSTORE_PASSPHRASE"

_SECRETS = (("ml_dsa", "pq.sec", "pq.pub"),
            ("slh_dsa", "slh.sec", "slh.pub"),
            ("ed25519", "ed25519.sec", "ed25519.pub"))


class KeystoreError(Exception):
    """Sealing or unsealing failed."""


def _b64(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


def _unb64(s: str) -> bytes:
    return base64.b64decode(s, validate=True)


def _canonical(obj: Any) -> bytes:
    """Stable header bytes for use as AEAD associated data."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _derive(passphrase: str, salt: bytes, n: int, r: int, p: int) -> bytes:
    return Scrypt(salt=salt, length=KEY_LEN, n=n, r=r, p=p).derive(
        passphrase.encode("utf-8")
    )


def read_passphrase(confirm: bool = False) -> str:
    """Read the passphrase from the environment or an interactive prompt.

    Never accepted on the command line: argv is visible to every process on
    the machine via `ps`.
    """
    env = os.environ.get(PASSPHRASE_ENV)
    if env:
        return env
    if not sys.stdin.isatty():
        raise KeystoreError(
            f"no passphrase: set {PASSPHRASE_ENV} or run interactively"
        )
    pw = getpass.getpass("Keystore passphrase: ")
    if not pw:
        raise KeystoreError("empty passphrase")
    if confirm and getpass.getpass("Confirm passphrase: ") != pw:
        raise KeystoreError("passphrases do not match")
    return pw


def fingerprint(pk: bytes) -> str:
    """SHA-256 of a public key — the same value the zkVM guest commits and
    MLDSAAttestation pins as `agentPkHash`."""
    return hashlib.sha256(pk).hexdigest()


def seal(keys_dir: Path | str, out_path: Path | str, passphrase: str) -> dict[str, str]:
    """Encrypt the secret keys in `keys_dir` into a single sealed file.

    Returns the identity fingerprints, so the caller can record which identity
    was sealed. The public keys are stored in cleartext inside the file.
    """
    keys_dir, out_path = Path(keys_dir), Path(out_path)

    secrets: dict[str, str] = {}
    identity: dict[str, str] = {}
    for name, sec, pub in _SECRETS:
        sec_p, pub_p = keys_dir / sec, keys_dir / pub
        if not sec_p.exists() or not pub_p.exists():
            raise KeystoreError(f"missing {sec} or {pub} in {keys_dir.resolve()}")
        sk, pk = sec_p.read_bytes(), pub_p.read_bytes()
        secrets[name] = _b64(sk)
        identity[f"{name}_pk"] = _b64(pk)
        identity[f"{name}_fpr"] = fingerprint(pk)

    salt = os.urandom(16)
    nonce = os.urandom(NONCE_LEN)
    header = {
        "version": KEYSTORE_VERSION,
        "cipher": "chacha20poly1305",
        "kdf": {"name": "scrypt", "n": SCRYPT_N, "r": SCRYPT_R, "p": SCRYPT_P,
                "salt": _b64(salt)},
        "nonce": _b64(nonce),
        "identity": identity,
    }
    key = _derive(passphrase, salt, SCRYPT_N, SCRYPT_R, SCRYPT_P)
    ct = ChaCha20Poly1305(key).encrypt(
        nonce, _canonical(secrets), _canonical(header)
    )

    doc = dict(header)
    doc["ciphertext"] = _b64(ct)
    out_path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    os.chmod(out_path, stat.S_IRUSR | stat.S_IWUSR)   # 0600
    return {k: v for k, v in identity.items() if k.endswith("_fpr")}


def read_identity(path: Path | str) -> dict[str, str]:
    """Return the public identity of a sealed file WITHOUT the passphrase.

    This is the check that was missing: it answers "which agent is this?"
    before you commit to using it, and it works on a backup you cannot open.
    """
    doc = json.loads(Path(path).read_text())
    if doc.get("version") != KEYSTORE_VERSION:
        raise KeystoreError(f"unsupported keystore version: {doc.get('version')}")
    return dict(doc["identity"])


def unseal(path: Path | str, passphrase: str) -> dict[str, bytes]:
    """Decrypt and return the secret keys keyed by algorithm name."""
    doc = json.loads(Path(path).read_text())
    if doc.get("version") != KEYSTORE_VERSION:
        raise KeystoreError(f"unsupported keystore version: {doc.get('version')}")

    header = {k: v for k, v in doc.items() if k != "ciphertext"}
    kdf = header["kdf"]
    key = _derive(passphrase, _unb64(kdf["salt"]), kdf["n"], kdf["r"], kdf["p"])
    try:
        pt = ChaCha20Poly1305(key).decrypt(
            _unb64(header["nonce"]), _unb64(doc["ciphertext"]), _canonical(header)
        )
    except InvalidTag as exc:
        raise KeystoreError(
            "decryption failed: wrong passphrase, or the file's public header "
            "was modified (it is authenticated, so edits invalidate it)"
        ) from exc
    return {k: _unb64(v) for k, v in json.loads(pt).items()}


def restore(path: Path | str, keys_dir: Path | str, passphrase: str) -> dict[str, str]:
    """Unseal into `keys_dir`, refusing to clobber an existing identity.

    Verifies each restored secret key against the public key recorded in the
    cleartext header, so a corrupted or mismatched file is caught here rather
    than at signing time.
    """
    keys_dir = Path(keys_dir)
    keys_dir.mkdir(parents=True, exist_ok=True)
    for _, sec, _pub in _SECRETS:
        if (keys_dir / sec).exists():
            raise KeystoreError(
                f"{keys_dir / sec} already exists — refusing to overwrite an "
                "existing signing identity. Move it aside deliberately."
            )

    identity = read_identity(path)
    secrets = unseal(path, passphrase)

    from . import pq_signing as pq  # local import: keystore must stay importable alone

    for name, sec, pub in _SECRETS:
        sk = secrets[name]
        pk = _unb64(identity[f"{name}_pk"])
        (keys_dir / pub).write_bytes(pk)
        (keys_dir / sec).write_bytes(sk)
        os.chmod(keys_dir / sec, stat.S_IRUSR | stat.S_IWUSR)
        os.chmod(keys_dir / pub,
                 stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)

    # Prove the restored secret actually corresponds to the advertised public
    # key, rather than trusting the file's own claim about itself.
    probe = {"keystore-selftest": True}
    checks = {
        "ml_dsa": pq.verify(probe, pq.sign(probe, secrets["ml_dsa"]),
                            _unb64(identity["ml_dsa_pk"])),
        "slh_dsa": pq.slh_dsa_verify(probe, pq.slh_dsa_sign(probe, secrets["slh_dsa"]),
                                     _unb64(identity["slh_dsa_pk"])),
        "ed25519": pq.ed25519_verify(probe, pq.ed25519_sign(probe, secrets["ed25519"]),
                                     _unb64(identity["ed25519_pk"])),
    }
    if not all(checks.values()):
        raise KeystoreError(f"restored keypair self-test failed: {checks}")
    return {k: v for k, v in identity.items() if k.endswith("_fpr")}


def _main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    if cmd == "seal" and len(argv) == 4:
        fprs = seal(argv[2], argv[3], read_passphrase(confirm=True))
        print(f"Sealed {argv[2]} -> {argv[3]} (0600)")
        for k, v in fprs.items():
            print(f"  {k:14} {v}")
        print("\nStore this file off-machine. Keep the passphrase somewhere else.")
        return 0
    if cmd == "identity" and len(argv) == 3:
        for k, v in read_identity(argv[2]).items():
            if k.endswith("_fpr"):
                print(f"{k:14} {v}")
        return 0
    if cmd == "open" and len(argv) == 4:
        fprs = restore(argv[2], argv[3], read_passphrase())
        print(f"Restored {argv[2]} -> {argv[3]}/ (self-test passed)")
        for k, v in fprs.items():
            print(f"  {k:14} {v}")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
