# Cutrans repository instructions

Read [MEMORY.md](MEMORY.md) and [current status](docs/memory/current.md) before making changes. They distinguish current implementation, historical evidence and future plans.

- VM owns documents, resources, authorization and jobs. Shell/App state is a projection.
- Append decisions and actual validation to project memory; preserve historical records. Record untested boundaries explicitly.
- Use `tools/dev.ps1` for Windows developer commands. Automated builds/tests must keep console windows hidden and retain logs and exit codes.
- Keep runtime data, credentials, caches and verification evidence out of Git. Ignored files are not automatically safe to delete; follow [repository ownership](docs/development/repository-layout.md).
- Do not change vendor sources without reviewing provenance and updating the effective dependency lock deliberately.
- No screenshots or real keyboard/mouse automation. Real GUI/IME and installation acceptance are separate from headless checks.
- Run `tools/dev.ps1 verify-repository` plus validation appropriate to the change. Do not publish, rewrite Git history or claim installer acceptance as a side effect of routine source cleanup.
