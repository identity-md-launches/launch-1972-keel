# Vendored dependencies

Dependencies are ordinary source files, not git submodules. They are sufficient
to build and test without fetching packages. Upstream source files and licenses
are unmodified; `lib/SHA256SUMS` records the SHA-256 of every vendored file.

| Dependency | Version | Included files | License |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | `v5.0.2` | ERC20, IERC20, IERC20Metadata, Context, draft-IERC6093, LICENSE | MIT |
| forge-std | `v1.9.7` | `src/`, LICENSE-APACHE, LICENSE-MIT | Apache-2.0 OR MIT |

OpenZeppelin source: <https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2>.
Files were obtained from the tagged paths under
`https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.2/`.
Only the ERC20 implementation's transitive source dependencies are included.

forge-std source: <https://github.com/foundry-rs/forge-std/tree/v1.9.7>.
The source and licenses were extracted from
`https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7`.
That archive's SHA-256 is
`45157353ab49eab01d294565866731e599b32401757229689ee459aa26b7ee94`.
forge-std is used only by tests; it is not part of Keel's deployed bytecode.

License texts are at `lib/openzeppelin-contracts/LICENSE`,
`lib/forge-std/LICENSE-APACHE`, and `lib/forge-std/LICENSE-MIT`.
