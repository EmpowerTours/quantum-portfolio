use sp1_build::{build_program_with_args, BuildArgs};

/// Build the SP1 guest REPRODUCIBLY.
///
/// The program vkey is a hash of the compiled guest ELF, and
/// `MLDSAAttestation` pins it as an immutable. If the ELF is not
/// byte-reproducible, nobody can confirm that the vkey on chain corresponds to
/// the source in this repository — the on-chain attestation then reduces to
/// "trust the submitter", which defeats the point of publishing it.
///
/// That is not hypothetical: an earlier non-reproducible build produced vkey
/// 0x00ed29f3… on a rented proving box and 0x00364772… on the dev box, from
/// identical source. Only the former verifies against the deployed contract.
///
/// Two changes fix it, and both are required:
///   * `docker: true` — compiles inside the pinned ghcr.io/succinctlabs/sp1
///     image instead of against whatever toolchain the host happens to have.
///   * `tag` pinned to an explicit release rather than the crate default,
///     so the image itself cannot drift underneath us.
///
/// `rust-toolchain` is pinned to an explicit version for the same reason —
/// `channel = "stable"` is a moving target that guarantees drift over time.
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
