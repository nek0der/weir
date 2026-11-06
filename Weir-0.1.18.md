## [0.1.18](https://github.com/nek0der/weir/compare/v0.1.17...v0.1.18) (2026-11-06)


### Features

* **keyboard:** reach the decision bar's menu, the sidebar's clean-up, and a notice's Undo by keyboard ([#300](https://github.com/nek0der/weir/issues/300)) ([369d633](https://github.com/nek0der/weir/commit/369d633d2618e0d378e4f5dafc1a72d1c6baf822))


### Bug Fixes

* **agent:** keep a finished Codex run at rest while a subagent it started works on after the turn ([#333](https://github.com/nek0der/weir/issues/333)) ([f77fc43](https://github.com/nek0der/weir/commit/f77fc43c09fb8c675aacb1eea7739090fd9e3c83))
* **agent:** keep a subagent's wait past the parent's stop until that subagent's own tool ([#350](https://github.com/nek0der/weir/issues/350)) ([cd04600](https://github.com/nek0der/weir/commit/cd04600c8763cfe034e59218967192007b6c07d4))
* **agent:** stop one worktree's Debug build from pointing another's Claude sessions at its hooks ([#342](https://github.com/nek0der/weir/issues/342)) ([21f5010](https://github.com/nek0der/weir/commit/21f5010166555f49f1170df8bafbfdcda48141c1))
* **agent:** stop the hook's Git starting a repository's fsmonitor or hooks, and keep the hook log private ([#334](https://github.com/nek0der/weir/issues/334)) ([78dae68](https://github.com/nek0der/weir/commit/78dae6810e4139a8d7fcbab1604a9a9878bc6aa7))
* **approval:** draw the whole focus ring around the question card's Other answer field ([#328](https://github.com/nek0der/weir/issues/328)) ([2d17364](https://github.com/nek0der/weir/commit/2d17364b4e05efd41d79a4464c7cb39f24be3f76))
* **approval:** hand over every held request at quit, and refuse one whose hook has gone ([#357](https://github.com/nek0der/weir/issues/357)) ([f54dc79](https://github.com/nek0der/weir/commit/f54dc795bac5be2fdbed50d150fb0b2ab1c1d699))
* **approval:** keep waits on the service from stalling the app, and replace the service if it stops answering ([#306](https://github.com/nek0der/weir/issues/306)) ([c17143d](https://github.com/nek0der/weir/commit/c17143de1ce12a82685d11687570d04c40e229a7))
* **approval:** open the card by one rule everywhere, and only for a request Weir can still answer ([#316](https://github.com/nek0der/weir/issues/316)) ([3d20d09](https://github.com/nek0der/weir/commit/3d20d0981f9de1c6d3e4ede98dceb74d5816557c))
* **approval:** refuse a call to an invalidated service client at once, instead of waiting on XPC ([#317](https://github.com/nek0der/weir/issues/317)) ([15c8620](https://github.com/nek0der/weir/commit/15c8620a26637717f6da049e6f4e39cd5cacf326))
* **claude:** stop running a project's status line command when the launch leaves its settings out ([#356](https://github.com/nek0der/weir/issues/356)) ([eff0e1b](https://github.com/nek0der/weir/commit/eff0e1b588cc6e5691a4823ffd06ea9233256064))
* **codex:** stop rewriting ~/.codex/config.toml at launch, and leave the trust tables earlier builds wrote ([#331](https://github.com/nek0der/weir/issues/331)) ([52b738e](https://github.com/nek0der/weir/commit/52b738ea37b5ecb301b28a8328575ca40b9ebfe8))
* **confirmations:** ask before quitting while an agent runs in the Quick Terminal ([#338](https://github.com/nek0der/weir/issues/338)) ([f559507](https://github.com/nek0der/weir/commit/f55950735f50948fff0bc3bb52ce0c268d616b38))
* **design:** keep each monospaced font Weir makes, so measuring text in one no longer aborts ([#353](https://github.com/nek0der/weir/issues/353)) ([f05a8c7](https://github.com/nek0der/weir/commit/f05a8c78d26066face1a9d9a67a3178bbae24a21))
* **keyboard:** send ⌥⌫ once, make ⌘⌫ delete a notification, and stop a mouse's back button pasting ([#326](https://github.com/nek0der/weir/issues/326)) ([451773f](https://github.com/nek0der/weir/commit/451773f460284781fdb1797349746aab546c727b))
* **l10n:** say shared words one way, and in Japanese tell a check that passed after failures from a failed one ([#310](https://github.com/nek0der/weir/issues/310)) ([0b05ce3](https://github.com/nek0der/weir/commit/0b05ce399381eb73a7311e152611b2d054f2c3a2))
* **palette:** enable each palette row when its menu item is, and run what the item runs ([#311](https://github.com/nek0der/weir/issues/311)) ([16b25ea](https://github.com/nek0der/weir/commit/16b25eadc4e1be2f316e48036232e8d9d6f93e53))
* **persistence:** keep files Weir cannot read, say when a save fails, and finish writes at quit ([#343](https://github.com/nek0der/weir/issues/343)) ([e83dd3a](https://github.com/nek0der/weir/commit/e83dd3a625c498e9d0fe6984a526f943a08e9662))
* **review:** bring the review tab back in front when the row's last terminal tab closes ([#314](https://github.com/nek0der/weir/issues/314)) ([c471bc3](https://github.com/nek0der/weir/commit/c471bc30c073db14c2ef6de74415703e796e5798))
* **review:** read the base as a branch, not a tag of the same name, and count submodules in every total ([#336](https://github.com/nek0der/weir/issues/336)) ([f4a658d](https://github.com/nek0der/weir/commit/f4a658d430296b2cd1eb85e3e59669002cad0599))
* **review:** tell the agent when a comment's quote is cut, and check a cut line by its start ([#345](https://github.com/nek0der/weir/issues/345)) ([39f2038](https://github.com/nek0der/weir/commit/39f2038b895b8fbd4e0ca5a8c32a30182e3a0743))
* **session:** keep restored tabs' scrollback through a close or a failed terminal, and drop repeated tab IDs ([#325](https://github.com/nek0der/weir/issues/325)) ([14beb42](https://github.com/nek0der/weir/commit/14beb42b8b87a98cdc69dcf2695870878a296c1b))
* **sidebar:** keep a row's pull request when its remotes cannot be read ([#352](https://github.com/nek0der/weir/issues/352)) ([6c6f790](https://github.com/nek0der/weir/commit/6c6f790cc1036a25c07321332032ebca2515745b))
* **supervision:** announce more waits, and let VoiceOver read rows and skip hidden controls ([#358](https://github.com/nek0der/weir/issues/358)) ([da6d1aa](https://github.com/nek0der/weir/commit/da6d1aa381290e179e9b252cc075c0bee519b89e))
* **supervision:** line up the Changes panel's agent badges with or without a color bar ([#332](https://github.com/nek0der/weir/issues/332)) ([f795beb](https://github.com/nek0der/weir/commit/f795beb76216a84b587ead275cd0419e0d90a0cd))
* **supervision:** show a gone item's nearest folder in Finder, and add Open in to diff file headers ([#312](https://github.com/nek0der/weir/issues/312)) ([e486aab](https://github.com/nek0der/weir/commit/e486aaba3946bd52737a494a23ecc5383e39b8c5))
* **support:** keep a verification channel run's preferences apart from the person's ([#355](https://github.com/nek0der/weir/issues/355)) ([c76084e](https://github.com/nek0der/weir/commit/c76084efa28abd026f63341c2fc99bcd18358ae1))
* **surface:** accept text an accessibility client writes into a pane, and paste several lines as one ([#304](https://github.com/nek0der/weir/issues/304)) ([4783cf9](https://github.com/nek0der/weir/commit/4783cf9a7cec88d2e5113a41eed34b7427a73689))
* **surface:** keep a newline in the folder a shell reports, so a pane holds its real path ([#341](https://github.com/nek0der/weir/issues/341)) ([6aa7491](https://github.com/nek0der/weir/commit/6aa749136f656d3aa49de90dae021339420afe67))
* **tmux:** start an agent hosted in tmux with its own pane's environment, not the server's ([#327](https://github.com/nek0der/weir/issues/327)) ([af86116](https://github.com/nek0der/weir/commit/af8611659484d48df76f255eb58276aaaed2d21b))
* **updates:** keep each check's timer to that check, make Retry check again, and show the update's version ([#337](https://github.com/nek0der/weir/issues/337)) ([6b2c236](https://github.com/nek0der/weir/commit/6b2c2369a71ef381aedb722c1632406796aad800))
* **worktree:** carry a case-only rename instead of refusing it as a file Git ignores ([#344](https://github.com/nek0der/weir/issues/344)) ([48017b7](https://github.com/nek0der/weir/commit/48017b71d2b298b51ea2e125429882c45a2c150a))
* **worktree:** carry changes without writing over ignored files, and keep a copy when Git stops part way ([#330](https://github.com/nek0der/weir/issues/330)) ([5f7852b](https://github.com/nek0der/weir/commit/5f7852bd129f90c9718201c9c8c3a95e08bab50d))
* **worktree:** kill a stopped setup step on time while Git reads fill the global queues ([#318](https://github.com/nek0der/weir/issues/318)) ([a9d90f1](https://github.com/nek0der/weir/commit/a9d90f1a2ee884ecec24c93a7c46458290716bb9))
* **worktree:** show a newline in a folder's name as a symbol instead of dropping it ([#329](https://github.com/nek0der/weir/issues/329)) ([1fe64d5](https://github.com/nek0der/weir/commit/1fe64d579eead277276eb6cec2ccb1de44428889))
* **worktree:** stop a setup step that starts while Weir quits, or keep it from starting ([#340](https://github.com/nek0der/weir/issues/340)) ([4c3d24d](https://github.com/nek0der/weir/commit/4c3d24d91bf5388b5e9c545f863c1348587ae2cc))


### Performance

* **sidebar:** look up each project's pull requests in one query, and wait out a rate limit ([#319](https://github.com/nek0der/weir/issues/319)) ([4f47241](https://github.com/nek0der/weir/commit/4f47241047f2dc1d71d9f806e587ab500ed95938))


### Refactors

* **agent:** copy and free the Rust bridge's bytes in one place, and type what crosses it ([#305](https://github.com/nek0der/weir/issues/305)) ([a70ebee](https://github.com/nek0der/weir/commit/a70ebeefacc789b67bdae5d76fa2d542532b3446))
* **agent:** read each agent's names, homes, and badge from one place, and quote shell words one way ([#315](https://github.com/nek0der/weir/issues/315)) ([5b12335](https://github.com/nek0der/weir/commit/5b12335c713ad277007fc21bc8ef338aacaa2510))
* **core:** give each agent-state, turn, and pane predicate one owner in the domain ([#320](https://github.com/nek0der/weir/issues/320)) ([8b3f5bd](https://github.com/nek0der/weir/commit/8b3f5bd7681932e899f1cd962fa88a259c12a555))
* **core:** let the main actor own the static hooks, so the compiler checks each access ([#302](https://github.com/nek0der/weir/issues/302)) ([01bc135](https://github.com/nek0der/weir/commit/01bc135ede029dedcd1dbdd58cf558e098223acc))
* **core:** remove dead symbols and duplicate helpers, and show a branch named like a tag by its name ([#303](https://github.com/nek0der/weir/issues/303)) ([1b53e22](https://github.com/nek0der/weir/commit/1b53e228f72b0add60837f2434471090eef08061))
* **keyboard:** mask a key event's command, control, option, and shift keys in one place ([#324](https://github.com/nek0der/weir/issues/324)) ([188cd1d](https://github.com/nek0der/weir/commit/188cd1d07da7f2d46c530acde0ae86a066e87834))
* **keyboard:** take each menu item's name and icon from its action, so menus match the palette ([#307](https://github.com/nek0der/weir/issues/307)) ([c772045](https://github.com/nek0der/weir/commit/c7720452d4eba60561215000e075de65531afd5d))
* **persistence:** tell a missing file from an unreadable one in one place, and say what a save did ([#323](https://github.com/nek0der/weir/issues/323)) ([6cee999](https://github.com/nek0der/weir/commit/6cee9990ddaf6157a90f53cde0d9a7c9a22dae25))
* **session:** decide which scrollback files a tab keeps in one place ([#322](https://github.com/nek0der/weir/issues/322)) ([3d74aa1](https://github.com/nek0der/weir/commit/3d74aa10088d3d314233411d68469d3dc9240b97))
* **settings:** open Settings through one opener from every menu, row, and button ([#313](https://github.com/nek0der/weir/issues/313)) ([a463ca3](https://github.com/nek0der/weir/commit/a463ca3b10b9151e8acfe71c4e8a8203710eefe9))
* **worktree:** give each of the carry's repeated Git reads one helper, and split clearing the source into its check and its write ([#321](https://github.com/nek0der/weir/issues/321)) ([eba1b88](https://github.com/nek0der/weir/commit/eba1b88f6047d40d32d1b589e284810d819454db))


### Documentation

* **agent:** define the commit types, scopes, branch prefixes, and subject rules ([#349](https://github.com/nek0der/weir/issues/349)) ([9eb13e4](https://github.com/nek0der/weir/commit/9eb13e4a26e3b2987393b417f0516e1710365d7c))
* **agent:** share a procedure for adding, strengthening, consolidating, and removing tests ([#346](https://github.com/nek0der/weir/issues/346)) ([38959a8](https://github.com/nek0der/weir/commit/38959a89fb715640ce54c71785ddd8b1af11b596))
* **agent:** share verification steps and streamline contributor and agent instructions ([#339](https://github.com/nek0der/weir/issues/339)) ([b53da4d](https://github.com/nek0der/weir/commit/b53da4d408234116ff70bb38312f302483cd3a48))
* **agent:** share writing rules for comments, documents, commits, and pull requests ([#335](https://github.com/nek0der/weir/issues/335)) ([9a9fcd9](https://github.com/nek0der/weir/commit/9a9fcd9a6efc22357b1062f8b4076ca99764382d))

## What's Changed
* chore(log): lower the per-event logs and keep every line in the subsystem by @nek0der in https://github.com/nek0der/weir/pull/299
* feat(keyboard): reach the decision bar's menu, the sidebar's clean-up, and a notice's Undo by keyboard by @nek0der in https://github.com/nek0der/weir/pull/300
* refactor(core): let the main actor own the static hooks, so the compiler checks each access by @nek0der in https://github.com/nek0der/weir/pull/302
* refactor(core): remove dead symbols and duplicate helpers, and show a branch named like a tag by its name by @nek0der in https://github.com/nek0der/weir/pull/303
* fix(surface): accept text an accessibility client writes into a pane, and paste several lines as one by @nek0der in https://github.com/nek0der/weir/pull/304
* refactor(agent): copy and free the Rust bridge's bytes in one place, and type what crosses it by @nek0der in https://github.com/nek0der/weir/pull/305
* fix(approval): keep waits on the service from stalling the app, and replace the service if it stops answering by @nek0der in https://github.com/nek0der/weir/pull/306
* refactor(keyboard): take each menu item's name and icon from its action, so menus match the palette by @nek0der in https://github.com/nek0der/weir/pull/307
* chore(build): make every script use this checkout's build, not the newest one in DerivedData by @nek0der in https://github.com/nek0der/weir/pull/308
* fix(palette): enable each palette row when its menu item is, and run what the item runs by @nek0der in https://github.com/nek0der/weir/pull/311
* test(support): set up folders, Git repositories, child processes, and shims through the shared fixtures by @nek0der in https://github.com/nek0der/weir/pull/309
* fix(l10n): say shared words one way, and in Japanese tell a check that passed after failures from a failed one by @nek0der in https://github.com/nek0der/weir/pull/310
* fix(supervision): show a gone item's nearest folder in Finder, and add Open in to diff file headers by @nek0der in https://github.com/nek0der/weir/pull/312
* fix(review): bring the review tab back in front when the row's last terminal tab closes by @nek0der in https://github.com/nek0der/weir/pull/314
* fix(worktree): kill a stopped setup step on time while Git reads fill the global queues by @nek0der in https://github.com/nek0der/weir/pull/318
* fix(approval): refuse a call to an invalidated service client at once, instead of waiting on XPC by @nek0der in https://github.com/nek0der/weir/pull/317
* refactor(settings): open Settings through one opener from every menu, row, and button by @nek0der in https://github.com/nek0der/weir/pull/313
* refactor(agent): read each agent's names, homes, and badge from one place, and quote shell words one way by @nek0der in https://github.com/nek0der/weir/pull/315
* fix(approval): open the card by one rule everywhere, and only for a request Weir can still answer by @nek0der in https://github.com/nek0der/weir/pull/316
* refactor(core): give each agent-state, turn, and pane predicate one owner in the domain by @nek0der in https://github.com/nek0der/weir/pull/320
* perf(sidebar): look up each project's pull requests in one query, and wait out a rate limit by @nek0der in https://github.com/nek0der/weir/pull/319
* refactor(worktree): give each of the carry's repeated Git reads one helper, and split clearing the source into its check and its write by @nek0der in https://github.com/nek0der/weir/pull/321
* refactor(session): decide which scrollback files a tab keeps in one place by @nek0der in https://github.com/nek0der/weir/pull/322
* refactor(persistence): tell a missing file from an unreadable one in one place, and say what a save did by @nek0der in https://github.com/nek0der/weir/pull/323
* refactor(keyboard): mask a key event's command, control, option, and shift keys in one place by @nek0der in https://github.com/nek0der/weir/pull/324
* fix(session): keep restored tabs' scrollback through a close or a failed terminal, and drop repeated tab IDs by @nek0der in https://github.com/nek0der/weir/pull/325
* fix(keyboard): send ⌥⌫ once, make ⌘⌫ delete a notification, and stop a mouse's back button pasting by @nek0der in https://github.com/nek0der/weir/pull/326
* fix(tmux): start an agent hosted in tmux with its own pane's environment, not the server's by @nek0der in https://github.com/nek0der/weir/pull/327
* fix(approval): draw the whole focus ring around the question card's Other answer field by @nek0der in https://github.com/nek0der/weir/pull/328
* fix(worktree): show a newline in a folder's name as a symbol instead of dropping it by @nek0der in https://github.com/nek0der/weir/pull/329
* fix(worktree): carry changes without writing over ignored files, and keep a copy when Git stops part way by @nek0der in https://github.com/nek0der/weir/pull/330
* fix(codex): stop rewriting ~/.codex/config.toml at launch, and leave the trust tables earlier builds wrote by @nek0der in https://github.com/nek0der/weir/pull/331
* fix(supervision): line up the Changes panel's agent badges with or without a color bar by @nek0der in https://github.com/nek0der/weir/pull/332
* fix(agent): keep a finished Codex run at rest while a subagent it started works on after the turn by @nek0der in https://github.com/nek0der/weir/pull/333
* fix(agent): stop the hook's Git starting a repository's fsmonitor or hooks, and keep the hook log private by @nek0der in https://github.com/nek0der/weir/pull/334
* docs(agent): share writing rules for comments, documents, commits, and pull requests by @nek0der in https://github.com/nek0der/weir/pull/335
* fix(updates): keep each check's timer to that check, make Retry check again, and show the update's version by @nek0der in https://github.com/nek0der/weir/pull/337
* fix(review): read the base as a branch, not a tag of the same name, and count submodules in every total by @nek0der in https://github.com/nek0der/weir/pull/336
* fix(confirmations): ask before quitting while an agent runs in the Quick Terminal by @nek0der in https://github.com/nek0der/weir/pull/338
* docs(agent): share verification steps and streamline contributor and agent instructions by @nek0der in https://github.com/nek0der/weir/pull/339
* fix(worktree): stop a setup step that starts while Weir quits, or keep it from starting by @nek0der in https://github.com/nek0der/weir/pull/340
* fix(surface): keep a newline in the folder a shell reports, so a pane holds its real path by @nek0der in https://github.com/nek0der/weir/pull/341
* fix(agent): stop one worktree's Debug build from pointing another's Claude sessions at its hooks by @nek0der in https://github.com/nek0der/weir/pull/342
* fix(persistence): keep files Weir cannot read, say when a save fails, and finish writes at quit by @nek0der in https://github.com/nek0der/weir/pull/343
* fix(worktree): carry a case-only rename instead of refusing it as a file Git ignores by @nek0der in https://github.com/nek0der/weir/pull/344
* fix(review): tell the agent when a comment's quote is cut, and check a cut line by its start by @nek0der in https://github.com/nek0der/weir/pull/345
* docs(agent): share a procedure for adding, strengthening, consolidating, and removing tests by @nek0der in https://github.com/nek0der/weir/pull/346
* ci(lint): require a lowercase subject and a kebab-case scope, and drop the unused style type by @nek0der in https://github.com/nek0der/weir/pull/347
* build(release): hide build and CI commits from the changelog, and drop the unused style section by @nek0der in https://github.com/nek0der/weir/pull/348
* docs(agent): define the commit types, scopes, branch prefixes, and subject rules by @nek0der in https://github.com/nek0der/weir/pull/349
* fix(agent): keep a subagent's wait past the parent's stop until that subagent's own tool by @nek0der in https://github.com/nek0der/weir/pull/350
* fix(sidebar): keep a row's pull request when its remotes cannot be read by @nek0der in https://github.com/nek0der/weir/pull/352
* ci: hand the tmux requirement to the test process, so a runner without tmux fails the tmux tests by @nek0der in https://github.com/nek0der/weir/pull/354
* test(support): drive the registrar, the debounced save, and the Codex usage read without the clock by @nek0der in https://github.com/nek0der/weir/pull/351
* fix(design): keep each monospaced font Weir makes, so measuring text in one no longer aborts by @nek0der in https://github.com/nek0der/weir/pull/353
* fix(support): keep a verification channel run's preferences apart from the person's by @nek0der in https://github.com/nek0der/weir/pull/355
* fix(claude): stop running a project's status line command when the launch leaves its settings out by @nek0der in https://github.com/nek0der/weir/pull/356
* fix(approval): hand over every held request at quit, and refuse one whose hook has gone by @nek0der in https://github.com/nek0der/weir/pull/357
* fix(supervision): announce more waits, and let VoiceOver read rows and skip hidden controls by @nek0der in https://github.com/nek0der/weir/pull/358
* chore(main): release 0.1.18 by @nek0der in https://github.com/nek0der/weir/pull/301


**Full Changelog**: https://github.com/nek0der/weir/compare/v0.1.17...v0.1.18

<!-- weir-source-commit: 594300420432a3523e3e40cfe13f0f9d7844365e -->
