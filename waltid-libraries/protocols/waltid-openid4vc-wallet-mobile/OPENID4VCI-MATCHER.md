# Vendored OpenID4VCI Credential Manager issuance matcher

`src/androidMain/assets/id/walt/wallet2/mobile/issuance.wasm` is the WebAssembly issuance matcher
registered for OpenID4VCI `CREATE_CREDENTIAL` creation options. AndroidX does not yet ship a released
OpenID4VCI registry helper in the SDK version used here, so `AndroidDigitalCredentialRegistry` still
uses a raw `RegisterCreationOptionsRequest` and supplies this binary.

The matcher is Google's Rust implementation from `android/identity-samples`, built from source at a
pinned commit. It is independent of the platform-neutral OpenID4VCI wallet engine: the matcher only
decides whether Credential Manager should surface this wallet, while the provider and wallet engine
parse and fulfil the selected issuance request.

## Provenance

The committed binary is our build of **unmodified upstream sources**; Google publishes the Rust source
tree, not this binary.

| | |
| --- | --- |
| Upstream repository | https://github.com/android/identity-samples |
| Branch | `wasm` |
| Immutable upstream commit | `5d966fc4913cac93f3b3b11e11bdd44d3e0b5c9e` |
| Source path | `CredentialProvider/wasm/matcher-rs` |
| Binary entry point | `src/bin/issuance.rs` |
| Source modifications | none |
| Exact built binary path | `target/wasm32-unknown-unknown/release/issuance.wasm` |
| Size | 91,794 bytes |
| SHA-256 | `07c610ab120949ae656ddbff99ec24ba6300d6baa4736cc59ecaa6285e730b46` |
| Rust toolchain | `rustc 1.99.0-nightly (12c36e253 2026-08-10)` |
| Target | `wasm32-unknown-unknown` |
| License | Apache-2.0 |

`NOTICE-issuance.txt` ships beside the binary. It records the Apache-2.0 source license and the
Apache-2.0, MIT, and LLVM-exception notices for the Rust standard library and crates compiled into the
WASM. The dependency list is generated with the pinned source tree's `generate_license.sh` procedure.

## Creation-options contract

The byte layout follows AndroidX `OpenId4VciRegistry` on `androidx-main`: a four-byte little-endian
JSON offset, optional icon bytes, then UTF-8 JSON. The JSON registered by this SDK contains:

```json
{
  "entry_id": "openid4vci",
  "entries": [
    {
      "subtitle": "Save a credential to this wallet",
      "explainer": { "default": "Save a credential to this wallet." }
    }
  ],
  "filter": { "Pass": {} },
  "preferred_protocols": ["openid4vci-v1"],
  "package_info": {
    "name": "<host application label>",
    "icon": [4, "4 + icon length"]
  }
}
```

`package_info` uses the host application's normal label and icon bytes, with offsets into the same
packed blob. It follows AndroidX's auto-resolved package metadata; this provider does not use the
privileged `self_declared_package_info` override.

The non-empty `preferred_protocols` list is load-bearing. The upstream matcher gives exact preferred
protocols precedence over its historical fallback list, so only `openid4vci-v1` is intentionally
advertised and matched here. The binary still contains upstream fallback literals such as
`openid4vci1.0`, but this registration never reaches that fallback. The Android provider separately
accepts only `openid4vci-v1`; no historical aliases are part of this SDK's public/provider contract.

The `Pass` filter is deliberately broad. It lets this wallet be surfaced as a candidate for supported
OpenID4VCI Digital Credentials API requests; the platform-neutral issuance engine remains responsible
for resolving the offer and deciding whether the flow can be fulfilled.

## Wasm/Credential Manager compatibility

The final Wasm import section uses the `credman` module and imports:

- `GetCredentialsSize`, `ReadCredentialsBuffer`, `GetRequestSize`, `GetRequestBuffer`, and
  `GetWasmVersion` to read the registered options and request;
- `AddIssuanceEntry` for Credential Manager Wasm ABI version 9 and newer;
- `AddStringIdEntry` as the match-result fallback for Wasm ABI versions below 9; and
- `SelfDeclarePackageInfo`, which is used only when a registration supplies
  `self_declared_package_info`.

The matcher is built unmodified, so compatibility assumes the supported Credential Manager/GMS
environment provides these `credman` imports. The older-version branch is retained by upstream, but
this migration does not expand the SDK's advertised Android or GMS support based on mocked tests.
Device validation must continue to cover the real Credential Manager picker and issuance handoff.

## Rebuilding and updating

Use an immutable upstream commit and build the source without edits:

```shell
git clone https://github.com/android/identity-samples
git -C identity-samples checkout 5d966fc4913cac93f3b3b11e11bdd44d3e0b5c9e
cd identity-samples/CredentialProvider/wasm/matcher-rs
rustup toolchain install nightly --component rust-src --target wasm32-unknown-unknown
cargo +nightly test
bash build.sh
bash generate_license.sh
cp target/wasm32-unknown-unknown/release/issuance.wasm \
  <this-module>/src/androidMain/assets/id/walt/wallet2/mobile/issuance.wasm
shasum -a 256 <this-module>/src/androidMain/assets/id/walt/wallet2/mobile/issuance.wasm
```

The committed hash is pinned by `AndroidVendoredMatcherTest`, and the AAR check verifies that both the
issuance binary and its notice are packaged. An intentional matcher update must update the binary,
hash, notice, provenance table, and compatibility review together.
