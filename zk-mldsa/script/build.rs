use sp1_build::{build_program_with_args, BuildArgs};

/// Build the SP1 guest REPRODUCIBLY.
///
/// The program vkey is a hash of the compiled guest ELF, and
/// `MLDSAAttestation` pins it as an immutable. If the ELF is not
/// byte-reproducible, nobody can confirm that the vkey on chain corresponds to
/// the source in this repository — the on-chain attestation then reduces to
/// "trust the submitter", which defeats the point of publishing it.
///
/// These pins are defence in depth, NOT the thing that makes the build
/// reproducible. This comment used to claim that identical source had produced
/// different vkeys on different machines and that `docker: true` had fixed it.
/// Measured on 2026-08-26: false. The same source yields a byte-identical ELF
/// across machines and across the docker and non-docker paths. Every vkey this
/// repo has seen came from a different SOURCE state.
///
/// The real hazard is the opposite of a toolchain bump, and much quieter.
/// `1e2ec67` grew the guest's `//!` header from three lines to four while
/// correcting a gas figure. `.expect(...)` embeds a
/// `core::panic::Location { file, line, col }`, so every line below it moved,
/// the ELF changed, and the vkey — an immutable on the deployed attestation —
/// no longer matched. Proofs built from that guest revert.
///
/// So: editing anything under `program/` is a contract change, comments
/// included. `verify_claims.py` pins a digest over every guest build input
/// (this file among them) and `--rebuild-guest` re-derives the vkey.
///
/// The pins are kept anyway: `docker: true` compiles inside the pinned
/// ghcr.io/succinctlabs/sp1 image, `tag` stops that image drifting, and
/// `rust-toolchain` names an explicit version rather than the moving
/// `stable`. They cost nothing and remove a variable.
fn main() {
    build_program_with_args(
        "../program",
        BuildArgs {
            docker: true,
            tag: "v6.3.1".to_string(),   // matches the RESOLVED sp1-build (6.3.1), not the Cargo.toml floor (6.0.1)
            ..Default::default()
        },
    )
}
