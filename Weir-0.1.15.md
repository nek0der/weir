## [0.1.15](https://github.com/nek0der/weir/compare/v0.1.14...v0.1.15) (2026-10-31)


### Features

* **supervision:** move Changes to the title bar and Scratch to the left rail ([#227](https://github.com/nek0der/weir/issues/227)) ([08eb3e7](https://github.com/nek0der/weir/commit/08eb3e7a2c67f0b8c2c954c91183762345435ed4))


### Bug Fixes

* **worktree:** name an agent's worktree folder after the whole branch, as the app does ([#219](https://github.com/nek0der/weir/issues/219)) ([aa6dba0](https://github.com/nek0der/weir/commit/aa6dba03c1d0ad7d0d4e2984ba118877b13a4ea7))


### Refactors

* **agent:** share the shims' handoff to the agent ([#226](https://github.com/nek0der/weir/issues/226)) ([4e17947](https://github.com/nek0der/weir/commit/4e179478b230081011248e378eaadfd1e3b07346))
* **claude:** read a question turn in the Claude crate ([#225](https://github.com/nek0der/weir/issues/225)) ([b187593](https://github.com/nek0der/weir/commit/b187593e4f45e29be135e628edd10d3186e2e667))
* **codex:** read a failed turn in the Codex crate ([#223](https://github.com/nek0der/weir/issues/223)) ([495187a](https://github.com/nek0der/weir/commit/495187a5240578798c00a43d085fe538806a5ce7))
* **codex:** read the hook events from the Codex crate ([#220](https://github.com/nek0der/weir/issues/220)) ([ac457f1](https://github.com/nek0der/weir/commit/ac457f1bc388d13a910f6fa0bf8315aa6a190724))
* **core:** stop Core naming the UI types ContainerSymbol and DropPosition ([#218](https://github.com/nek0der/weir/issues/218)) ([1800d73](https://github.com/nek0der/weir/commit/1800d732e1acfa7eab26816cd49aa5d13618069f))
* **domain:** move Domain into its own static module ([#216](https://github.com/nek0der/weir/issues/216)) ([1e12843](https://github.com/nek0der/weir/commit/1e12843a35a04ba07349b08b4d55a75d75bf1c88))
* **supervision:** rename the icon controls for what they are, and give the 32pt controls one corner radius ([#228](https://github.com/nek0der/weir/issues/228)) ([8ca432a](https://github.com/nek0der/weir/commit/8ca432adc60cee68321418814cb7a0118f72f659))

## What's Changed
* refactor(domain): move Domain into its own static module by @nek0der in https://github.com/nek0der/weir/pull/216
* refactor(core): stop Core naming the UI types ContainerSymbol and DropPosition by @nek0der in https://github.com/nek0der/weir/pull/218
* fix(worktree): name an agent's worktree folder after the whole branch, as the app does by @nek0der in https://github.com/nek0der/weir/pull/219
* refactor(codex): read the hook events from the Codex crate by @nek0der in https://github.com/nek0der/weir/pull/220
* chore(build): skip the release pull request's builds, and hold its merge until main passes by @nek0der in https://github.com/nek0der/weir/pull/222
* refactor(codex): read a failed turn in the Codex crate by @nek0der in https://github.com/nek0der/weir/pull/223
* test(agent): check the bound on a Stop's wait with a fake clock instead of timing the call by @nek0der in https://github.com/nek0der/weir/pull/224
* test(agent): check that a shim hands tmux every variable its recipe exports by @nek0der in https://github.com/nek0der/weir/pull/221
* refactor(agent): share the shims' handoff to the agent by @nek0der in https://github.com/nek0der/weir/pull/226
* refactor(claude): read a question turn in the Claude crate by @nek0der in https://github.com/nek0der/weir/pull/225
* feat(supervision): move Changes to the title bar and Scratch to the left rail by @nek0der in https://github.com/nek0der/weir/pull/227
* refactor(supervision): rename the icon controls for what they are, and give the 32pt controls one corner radius by @nek0der in https://github.com/nek0der/weir/pull/228
* chore(site): add the landing page and documents, and deploy them with each release by @nek0der in https://github.com/nek0der/weir/pull/229
* chore(main): release 0.1.15 by @nek0der in https://github.com/nek0der/weir/pull/217


**Full Changelog**: https://github.com/nek0der/weir/compare/v0.1.14...v0.1.15

<!-- weir-source-commit: 92353c13432d4dceb44b79b8621fc8fd2c25dc42 -->
