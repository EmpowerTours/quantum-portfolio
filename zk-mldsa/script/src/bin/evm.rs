//! Generate an EVM-verifiable (Groth16 / Plonk) proof of the ML-DSA-65
//! verification, and write a Solidity-consumable fixture.
//!
//!   cargo run --release --bin evm -- --system groth16
//!
//! The Groth16/Plonk wrap uses the gnark prover (Docker by default).

use alloy_sol_types::SolType;
use clap::{Parser, ValueEnum};
use fibonacci_lib::PublicValuesStruct;
use serde::{Deserialize, Serialize};
use sp1_sdk::{
    blocking::{ProveRequest, Prover, ProverClient},
    include_elf, Elf, HashableKey, ProvingKey, SP1ProofWithPublicValues, SP1Stdin, SP1VerifyingKey,
};
use std::path::PathBuf;

const MLDSA_ELF: Elf = include_elf!("fibonacci-program");

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct EVMArgs {
    #[arg(long, default_value = "mldsa_input.json")]
    input: String,
    #[arg(long, value_enum, default_value = "groth16")]
    system: ProofSystem,
}

#[derive(Copy, Clone, PartialEq, Eq, PartialOrd, Ord, ValueEnum, Debug)]
enum ProofSystem {
    Plonk,
    Groth16,
}

#[derive(Deserialize)]
struct Input {
    pk_hex: String,
    msg_hex: String,
    sig_hex: String,
}

/// Fixture for testing verification of the ML-DSA proof inside Solidity.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MLDSAProofFixture {
    order_hash: String,
    vkey: String,
    public_values: String,
    proof: String,
}

fn main() {
    sp1_sdk::utils::setup_logger();
    dotenv::dotenv().ok();

    let args = EVMArgs::parse();

    let input: Input =
        serde_json::from_slice(&std::fs::read(&args.input).expect("read input")).expect("parse");
    let pk_bytes = hex::decode(&input.pk_hex).unwrap();
    let msg = hex::decode(&input.msg_hex).unwrap();
    let sig = hex::decode(&input.sig_hex).unwrap();

    let client = ProverClient::from_env();
    let pk = client.setup(MLDSA_ELF).expect("failed to setup elf");

    let mut stdin = SP1Stdin::new();
    stdin.write(&pk_bytes);
    stdin.write(&msg);
    stdin.write(&sig);

    println!("Proof System: {:?}", args.system);

    let proof = match args.system {
        ProofSystem::Plonk => client.prove(&pk, stdin).plonk().run(),
        ProofSystem::Groth16 => client.prove(&pk, stdin).groth16().run(),
    }
    .expect("failed to generate proof");

    create_proof_fixture(&proof, pk.verifying_key(), args.system);
}

fn create_proof_fixture(proof: &SP1ProofWithPublicValues, vk: &SP1VerifyingKey, system: ProofSystem) {
    let bytes = proof.public_values.as_slice();
    let PublicValuesStruct { orderHash } = PublicValuesStruct::abi_decode(bytes).unwrap();

    let fixture = MLDSAProofFixture {
        order_hash: format!("0x{}", hex::encode(orderHash)),
        vkey: vk.bytes32().to_string(),
        public_values: format!("0x{}", hex::encode(bytes)),
        proof: format!("0x{}", hex::encode(proof.bytes())),
    };

    println!("Verification Key: {}", fixture.vkey);
    println!("orderHash: {}", fixture.order_hash);
    println!("Public Values: {}", fixture.public_values);
    println!("Proof Bytes: {}", fixture.proof);

    let fixture_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../contracts/src/fixtures");
    std::fs::create_dir_all(&fixture_path).expect("failed to create fixture path");
    std::fs::write(
        fixture_path.join(format!("{:?}-mldsa-fixture.json", system).to_lowercase()),
        serde_json::to_string_pretty(&fixture).unwrap(),
    )
    .expect("failed to write fixture");
    println!("Wrote fixture to contracts/src/fixtures/");
}
