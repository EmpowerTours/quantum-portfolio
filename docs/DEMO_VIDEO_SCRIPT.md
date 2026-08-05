# Demo Video — Narration Script

**Target:** 90 seconds. Companion to `docs/DEMO_VIDEO.mp4` (silent storyboard).

**How to record:** open `DEMO_VIDEO.mp4` in any player, hit record on OBS/Loom/iMovie, narrate the lines below. Each scene gets one breath. Don't rush — the silent track has a built-in 0.4s crossfade between scenes so a half-second pause feels natural.

**Voice direction:** calm, low-energy, technical. Don't sell. Let the proof sell.

---

| # | Scene (visual) | Hold | Narration (≤ words) |
|---|---|---|---|
| 1 | **Title — Q-Day-resistant DeFi** | 6 s | "EmpowerTours Quantum Portfolio. Q-Day-resistant DeFi, shipped today." *(13 words, ~5 s read time)* |
| 2 | **The threat — ECDSA hostage** | 9 s | "Every signature you publish on a public chain today is harvested. When a cryptographically relevant quantum computer arrives, every one of them is forgeable." *(25 words, ~8 s)* |
| 3 | **The stack — 3 layers** | 10 s | "Three layers. QAOA on IBM Heron picks the allocation. Hedged post-quantum signatures authenticate it. And every order's hash is anchored on Monad before the vault will execute it." *(31 words, ~9 s)* |
| 4 | **Streamlit — optimizer** | 9 s | "Here's the agent picking Markowitz-optimal weights, then running the same circuit on IBM Heron hardware. Error mitigation tripled how often it found the optimum — thirteen hits to thirty-nine, p equals zero point zero zero zero four." *(35 words, ~12 s)* |
| 5 | **Streamlit — hardware tab** | 10 s | "The circuit runs on real IBM Heron hardware. We ship the raw measurement counts, so you can recompute every number yourself without an IBM account. Honest measurement is the deliverable." *(30 words, ~10 s)* |
| 6 | **Streamlit — PQ signing** | 9 s | "Every order is signed three times. ML-DSA, SLH-DSA, and Ed25519. Two lattice and hash post-quantum families, plus a classical hedge. Any one survives." *(26 words, ~9 s)* |
| 7 | **Proof — live on Monad mainnet, 279 tests** | 10 s | "Live on Monad mainnet, all Monadscan-verified. Two hundred seventy-nine tests across Python and Foundry. The post-quantum signature is verified on-chain by a zero-knowledge proof. Reproducible from a cold clone." *(20 words, ~7 s)* — leave 3 s of silence for the numbers to land |
| 8 | **Live demo TX** | 10 s | "One transaction on Monad mainnet. A tenth of a MON in, real USDC out, lent straight into a live lending market. Tiny value on purpose — the point is that the contract refuses anything the agent didn't sign for." *(35 words, ~12 s)* |
| 9 | **Why now — the 2031 deadline** | 9 s | "This is not a someday problem. Executive Order 14412 requires post-quantum authentication by the thirty-first of December, twenty thirty-one. Authentication means signatures. That is exactly what this is." *(29 words, ~10 s)* |
| 10 | **The Ask — a 12-week paid pilot** | 8 s | "So the ask is not a cheque. Twelve weeks, one asset flow, pass-fail criteria agreed up front — and we will report failure as failure." *(25 words, ~9 s)* |

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
