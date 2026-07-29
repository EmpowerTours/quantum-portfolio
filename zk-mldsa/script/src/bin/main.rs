//! Host for the ML-DSA-65 zkVM verifier.
//!
//!   RUST_LOG=info cargo run --release --bin fibonacci -- --execute
//!   RUST_LOG=info cargo run --release --bin fibonacci -- --prove
//!
//! Reads the real (public key, canonical message, signature) triple exported
//! from the quantum pipeline (mldsa_input.json), feeds it to the guest, and
//! either executes it (cycle count + committed orderHash) or proves it.

use alloy_sol_types::SolType;
use clap::Parser;
use sha2::{Digest, Sha256};
use fibonacci_lib::PublicValuesStruct;
use serde::Deserialize;
use sp1_sdk::{
    blocking::{ProveRequest, Prover, ProverClient},
    include_elf, Elf, ProvingKey, SP1Stdin,
};

const MLDSA_ELF: Elf = include_elf!("fibonacci-program");

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    #[arg(long)]
    execute: bool,
    #[arg(long)]
    prove: bool,
    #[arg(long, default_value = "mldsa_input.json")]
    input: String,
}

#[derive(Deserialize)]
struct Input {
    pk_hex: String,
    msg_hex: String,
    sig_hex: String,
    digest: String,
}

fn main() {
    sp1_sdk::utils::setup_logger();
    dotenv::dotenv().ok();

    let args = Args::parse();
    if args.execute == args.prove {
        eprintln!("Error: specify either --execute or --prove");
        std::process::exit(1);
    }

    let input: Input =
        serde_json::from_slice(&std::fs::read(&args.input).expect("read mldsa_input.json"))
            .expect("parse mldsa_input.json");
    let pk = hex::decode(&input.pk_hex).expect("pk hex");
    let msg = hex::decode(&input.msg_hex).expect("msg hex");
    let sig = hex::decode(&input.sig_hex).expect("sig hex");
    println!(
        "ML-DSA-65: pk {} B, msg {} B, sig {} B; expected orderHash 0x{}",
        pk.len(),
        msg.len(),
        sig.len(),
        input.digest
    );

    let client = ProverClient::from_env();
    let mut stdin = SP1Stdin::new();
    stdin.write(&pk);
    stdin.write(&msg);
    stdin.write(&sig);

    if args.execute {
        let (output, report) = client.execute(MLDSA_ELF, stdin).run().unwrap();
        let decoded = PublicValuesStruct::abi_decode(output.as_slice()).unwrap();
        let committed = hex::encode(decoded.orderHash);
        let committed_pk = hex::encode(decoded.pkHash);
        let expected_pk = hex::encode(Sha256::digest(&pk));
        println!("Guest verified the ML-DSA-65 signature in the zkVM.");
        println!("committed orderHash: 0x{}", committed);
        println!("committed pkHash:    0x{}", committed_pk);
        assert_eq!(committed, input.digest, "committed orderHash != expected");
        println!("orderHash matches the on-chain anchored order.");
        // The guest must fingerprint the key it actually verified against;
        // MLDSAAttestation pins this value, so a mismatch here would mean any
        // keypair could mint an attestation. (Audit H-3.)
        assert_eq!(committed_pk, expected_pk, "committed pkHash != SHA-256(pk)");
        println!("pkHash matches SHA-256 of the supplied public key.");
        println!("zkVM cycles: {}", report.total_instruction_count());
    } else {
        let pk_setup = client.setup(MLDSA_ELF).expect("setup");
        let proof = client.prove(&pk_setup, stdin).run().expect("prove");
        client
            .verify(&proof, pk_setup.verifying_key(), None)
            .expect("verify");
        println!("Successfully generated and verified the ML-DSA-65 proof!");
    }
}
