**What and why**

**Checklist**

- [ ] `./scripts/test-all.sh` passes
- [ ] `nargo fmt --check`, `forge fmt --check`, `npm run lint` are clean
- [ ] Circuit changed? Ran `./scripts/build.sh` and `npm run fixtures`, committed the new verifier, artifact and fixtures
- [ ] Public input order still matches across `main.nr`, the registry and the SDK
- [ ] README / SECURITY.md updated if what is hidden or trusted changed
