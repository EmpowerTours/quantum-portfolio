"""IBM Quantum hardware access via Qiskit Runtime.

Loads the API token from .env (never hardcoded) and connects to the IBM
Quantum Platform. Used to list real QPUs and run QAOA on hardware.
"""
from __future__ import annotations

import os

from dotenv import load_dotenv
from qiskit_ibm_runtime import QiskitRuntimeService

load_dotenv()

# qiskit-ibm-runtime >= 0.40 accepts ONLY these two channels. The legacy
# "ibm_quantum" channel (quantum-computing.ibm.com) was retired along with the
# old platform, and passing it now raises ValueError rather than failing over —
# so keeping it in this tuple did not provide a fallback, it just replaced the
# real authentication error with a misleading one.
_CHANNELS = ("ibm_quantum_platform", "ibm_cloud")


def get_token() -> str:
    token = os.getenv("IBM_QUANTUM_TOKEN")
    if not token:
        raise RuntimeError("IBM_QUANTUM_TOKEN not set in .env")
    return token


def get_service() -> QiskitRuntimeService:
    token = get_token()
    last_err: Exception | None = None
    for channel in _CHANNELS:
        try:
            return QiskitRuntimeService(channel=channel, token=token)
        except Exception as exc:  # try next channel
            last_err = exc
    raise RuntimeError(
        f"Could not connect on any channel ({', '.join(_CHANNELS)}): {last_err!s}\n"
        "\n"
        "If this is 'Unable to retrieve instances', the token is not valid for "
        "the current IBM Quantum Platform. Tokens issued for the retired "
        "quantum-computing.ibm.com platform no longer authenticate, and an "
        "IBM Cloud token additionally needs an `instance` CRN.\n"
        "\n"
        "NOTE: none of the signing, anchoring or on-chain path needs this. "
        "run_pq_demo.py reads the recorded artefact in outputs/hardware_run*.json. "
        "Only re-running QAOA on real hardware requires a working credential."
    )


def list_backends(service: QiskitRuntimeService) -> list[dict]:
    info = []
    for b in service.backends(operational=True):
        try:
            status = b.status()
            info.append({
                "name": b.name,
                "qubits": b.num_qubits,
                "simulator": b.simulator,
                "pending_jobs": getattr(status, "pending_jobs", None),
            })
        except Exception:
            info.append({"name": b.name, "qubits": getattr(b, "num_qubits", "?"),
                         "simulator": getattr(b, "simulator", "?"),
                         "pending_jobs": None})
    return info


def least_busy_qpu(service: QiskitRuntimeService, min_qubits: int = 8):
    return service.least_busy(operational=True, simulator=False,
                              min_num_qubits=min_qubits)
