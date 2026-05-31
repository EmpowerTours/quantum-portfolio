# Demo Video — Narration Script

**Target:** 81 seconds. Companion to `docs/DEMO_VIDEO.mp4` (silent storyboard).

**How to record:** open `DEMO_VIDEO.mp4` in any player, hit record on OBS/Loom/iMovie, narrate the lines below. Each scene gets one breath. Don't rush — the silent track has a built-in 0.4s crossfade between scenes so a half-second pause feels natural.

**Voice direction:** calm, low-energy, technical. Don't sell. Let the proof sell.

---

| # | Scene (visual) | Hold | Narration (≤ words) |
|---|---|---|---|
| 1 | **Title — Q-Day-resistant DeFi** | 6 s | "EmpowerTours Quantum Portfolio. Q-Day-resistant DeFi, shipped today." *(13 words, ~5 s read time)* |
| 2 | **The threat — ECDSA hostage** | 9 s | "Every signature you publish on a public chain today is harvested. When a cryptographically relevant quantum computer arrives, every one of them is forgeable." *(25 words, ~8 s)* |
| 3 | **The stack — 3 layers** | 10 s | "Three layers. QAOA on IBM Heron picks the allocation. Hedged post-quantum signatures authenticate it. And every order's hash is anchored on Monad before the vault will execute it." *(31 words, ~9 s)* |
| 4 | **Streamlit — optimizer** | 9 s | "Here's the agent picking Markowitz-optimal weights. Twelve seeds, mean and standard deviation against an SLSQP baseline — no cherry-picking." *(22 words, ~8 s)* |
| 5 | **Streamlit — hardware tab** | 10 s | "The QAOA circuit runs on real hardware. IBM Heron, via Qiskit Runtime. Queue, depth, and qubit budget all visible. Honest measurement is the deliverable." *(26 words, ~9 s)* |
| 6 | **Streamlit — PQ signing** | 9 s | "Every order is signed three times. ML-DSA, SLH-DSA, and Ed25519. Two lattice and hash post-quantum families, plus a classical hedge. Any one survives." *(26 words, ~9 s)* |
| 7 | **Proof — six contracts, eighty-four tests** | 10 s | "Six contracts deployed and Monadscan-verified. Eighty-four tests passing across Python and Foundry. Reproducible from a cold clone." *(20 words, ~7 s)* — leave 3 s of silence for the numbers to land |
| 8 | **Live demo TX** | 10 s | "One transaction. Zero point one MON in. One hundred seventeen point five mUSDC and mUSDT out. Anchor-gated. Sandwich-resistant by construction." *(23 words, ~8 s)* |
| 9 | **The Ask — pilot with Santander** | 8 s | "Pilot with Santander. Q-Day-resistant treasury rails on infrastructure we can prove is honest." *(14 words, ~6 s)* |

---

## Backup: shorter version (60 s)

If Santander caps at 60 s, drop scenes 4 and 6 from the timeline (run `scripts/build_demo_video.py` after editing `TIMELINE`) and tighten the narration above to a single sentence per scene.

## Recording checklist

- [ ] Quiet room; headphone mic preferred over laptop mic.
- [ ] Record at 48 kHz mono; export the final mp4 at 44.1 kHz stereo for max portal compatibility.
- [ ] If your recorder embeds the camera feed, disable it — this is a tech demo, not a face cam.
- [ ] Loudness target: −16 LUFS (standard for spoken-word web video).
- [ ] After recording, verify the output plays in QuickTime *and* VLC before uploading.

## Post-production (optional, ~5 min)

- Drop the recorded audio over `DEMO_VIDEO.mp4` in iMovie / DaVinci Resolve / CapCut.
- Add the project URL as an end-card overlay on the final 2 s of scene 9: `github.com/EmpowerTours/quantum-portfolio · commit b3d8166`.
- Export H.264, 1080p, ≤ 25 MB to stay under most portal upload limits.
