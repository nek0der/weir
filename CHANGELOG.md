# Changelog

## [0.1.20](https://github.com/nek0der/weir/compare/v0.1.19...v0.1.20) (2026-11-13)


### Features

* **agent:** support the Kiro CLI ([#394](https://github.com/nek0der/weir/issues/394)) ([4f531fb](https://github.com/nek0der/weir/commit/4f531fb09e0d8dea4567e8531033ff8b63ab5ba4))


### Bug Fixes

* **agent:** build hook payloads in the runtime, so any agy payload or folder name reaches the record ([#400](https://github.com/nek0der/weir/issues/400)) ([03541b2](https://github.com/nek0der/weir/commit/03541b255744b53aeb55c70f0a4e3dd1868e0f41))
* **agent:** keep empty PATH entries when a shim looks for its agent ([#396](https://github.com/nek0der/weir/issues/396)) ([88890fb](https://github.com/nek0der/weir/commit/88890fbf535bc474cf9a776cc7150577384c7a2a))
* **agent:** place each agent's shared plugin and hooks under one lock, so launches never mix versions ([#401](https://github.com/nek0der/weir/issues/401)) ([45daf61](https://github.com/nek0der/weir/commit/45daf6128b5c5d7b21808e5bbed67ee98b2c6369))
* **support:** keep the agent check from answering trust prompts, and refuse typing while an agent waits ([#402](https://github.com/nek0der/weir/issues/402)) ([a1a7837](https://github.com/nek0der/weir/commit/a1a783797d5be082e00303a5f1d26c04bb0e1598))
* **support:** let the app decide where a posted key may land, and report one it dropped ([#398](https://github.com/nek0der/weir/issues/398)) ([c289974](https://github.com/nek0der/weir/commit/c2899748a2ffbd07e95d180e64a62b2ac5ae7381))


### Refactors

* **agent:** have the hook runtime read the host for the adapters, and check that no adapter does ([#399](https://github.com/nek0der/weir/issues/399)) ([12ffb1b](https://github.com/nek0der/weir/commit/12ffb1b30f244f6e68f4c7d28ec684c1644f074a))


### Documentation

* **site:** correct the OpenCode pages, keep to what Weir does, and match the app's wording ([#397](https://github.com/nek0der/weir/issues/397)) ([61b9a19](https://github.com/nek0der/weir/commit/61b9a199b058758032e8e8604c40c76457d77ab0))

## [0.1.19](https://github.com/nek0der/weir/compare/v0.1.18...v0.1.19) (2026-11-08)


### Bug Fixes

* **agent:** keep a restore's writes inside the worktree when a folder is replaced by a link ([#375](https://github.com/nek0der/weir/issues/375)) ([457fb3f](https://github.com/nek0der/weir/commit/457fb3f8211c8b656a52596c568a0973b0cf0073))
* **agent:** keep plan usage when one value is out of range, and keep a turn's passed check ([#363](https://github.com/nek0der/weir/issues/363)) ([189cddd](https://github.com/nek0der/weir/commit/189cdddf73159ddba91167e88a18673038271e32))
* **agent:** read the exported login PATH, and keep glob characters literal in shims ([#376](https://github.com/nek0der/weir/issues/376)) ([a0f9c56](https://github.com/nek0der/weir/commit/a0f9c5659bc6f55bec7e922e5d5a101c37dfcde1))
* **agent:** stop late reports from replacing a pane's newer agent or stop, and keep a reopened tab's run ([#364](https://github.com/nek0der/weir/issues/364)) ([e6f0ae2](https://github.com/nek0der/weir/commit/e6f0ae2fd2043dbf6f8f80ca9305be4e516396f6))
* **agent:** tell apart folder changes within one second, so a later worktree move is still suggested ([#384](https://github.com/nek0der/weir/issues/384)) ([19d7d29](https://github.com/nek0der/weir/commit/19d7d2954abdbfca6e3ac87323c7ee014960c2b7))
* **app:** report pull request, editor, and terminal configuration failures ([#381](https://github.com/nek0der/weir/issues/381)) ([1b94852](https://github.com/nek0der/weir/commit/1b94852271925d6ac44bee69f749cd8f7f6d6ed0))
* **approval:** release XPC waits synchronously, and keep test process cleanup bounded ([#386](https://github.com/nek0der/weir/issues/386)) ([4be2a05](https://github.com/nek0der/weir/commit/4be2a0526e1f456c92585181e94840aa56751ec2))
* **claude:** stop taking a tool result for a turn's prompt, so a cut-off count reads as partial ([#371](https://github.com/nek0der/weir/issues/371)) ([fadc748](https://github.com/nek0der/weir/commit/fadc7481dd53c8d964b57095b8b68098e5ed95ac))
* **core:** keep throttles and cache expiry right when the system clock moves ([#385](https://github.com/nek0der/weir/issues/385)) ([b6c3350](https://github.com/nek0der/weir/commit/b6c33500ca74d13cadb0bb3f7c207540418a40d1))
* **demo:** stop marking every demo project Folder Missing, so the fixture's counts show ([#383](https://github.com/nek0der/weir/issues/383)) ([78bc73a](https://github.com/nek0der/weir/commit/78bc73a6cc526e4937d9459c3fd36d04ad16b4b8))
* **demo:** use the default time of day when the demo clock names an invalid one ([#368](https://github.com/nek0der/weir/issues/368)) ([55d5ecc](https://github.com/nek0der/weir/commit/55d5ecc36256ac6d80992379e6f552c9f19bfbda))
* **design:** darken three light conversation colors so each mark stands out on a hovered row ([#369](https://github.com/nek0der/weir/issues/369)) ([c38b743](https://github.com/nek0der/weir/commit/c38b743b433eaac6f68621cbbf381360b1558254))
* **design:** give each state and command one icon and one color across the app ([#391](https://github.com/nek0der/weir/issues/391)) ([0085e2e](https://github.com/nek0der/weir/commit/0085e2e20c0363ecb83f2705d5331bd3285c25b9))
* **notifications:** show a dash for an unusable duration, and keep the history entry that holds it ([#366](https://github.com/nek0der/weir/issues/366)) ([c7ecf69](https://github.com/nek0der/weir/commit/c7ecf69a0a4caae3da3331ad8d1a11954c3c1920))
* **review:** cap the diffs Find keeps by their measured text bytes and rows ([#379](https://github.com/nek0der/weir/issues/379)) ([d668db5](https://github.com/nek0der/weir/commit/d668db5c8f476570014a61242c59b7ec1427ac06))
* **review:** keep file paths readable with compact marks and conversation tags ([#390](https://github.com/nek0der/weir/issues/390)) ([88e1f4b](https://github.com/nek0der/weir/commit/88e1f4b8ac938c948e2b499d098f391271c0c92c))
* **review:** search the files Find's note names, and keep each line's hunk header in a stacked file ([#361](https://github.com/nek0der/weir/issues/361)) ([c502657](https://github.com/nek0der/weir/commit/c5026570c20ea27ab079c361f3c5208b20a47be3))
* **review:** show newlines in file and folder names as symbols, so no name is cut short ([#380](https://github.com/nek0der/weir/issues/380)) ([8f09081](https://github.com/nek0der/weir/commit/8f090810fc191e86b68fbeb2ae54f427ed04a34a))
* **review:** stop a swapped path from reading a file outside the worktree or stalling the read ([#372](https://github.com/nek0der/weir/issues/372)) ([e5ef23f](https://github.com/nek0der/weir/commit/e5ef23ff887e6a9eb8abf81758a487385c2f3f21))
* **sidebar:** line up the project headers' marks and counts, and show an icon for another window ([#382](https://github.com/nek0der/weir/issues/382)) ([59f478b](https://github.com/nek0der/weir/commit/59f478b5157f600d1ecfc0b7e62167e3f1981a6d))
* **sidebar:** show a project's trouble as an icon in the count slot, so its name keeps its room ([#387](https://github.com/nek0der/weir/issues/387)) ([aa12490](https://github.com/nek0der/weir/commit/aa1249026616a926a6ea7fe2d3930e149476d024))
* **supervision:** keep a moved pane's own folder and the focus when the pane to split has closed ([#360](https://github.com/nek0der/weir/issues/360)) ([fb9ce6d](https://github.com/nek0der/weir/commit/fb9ce6df228f44ba245ed37b1b0c5f96a4f7c199))
* **supervision:** keep pane titles readable in splits, and show warnings as icons ([#388](https://github.com/nek0der/weir/issues/388)) ([6a74e8f](https://github.com/nek0der/weir/commit/6a74e8f2a4450b79db69920e13c370f490d6c83c))
* **supervision:** open the menu bar's Needs Attention list through accessibility presses ([#392](https://github.com/nek0der/weir/issues/392)) ([87abfdc](https://github.com/nek0der/weir/commit/87abfdc298049179a03829cfb763936f8024bc5c))
* **supervision:** show project activity and usage limits as icons so names keep their room ([#389](https://github.com/nek0der/weir/issues/389)) ([aa561f3](https://github.com/nek0der/weir/commit/aa561f3a8aef6b67ef04b9e07260210927f5d121))
* **surface:** keep a closed pane's late callbacks from reaching a new pane ([#374](https://github.com/nek0der/weir/issues/374)) ([baf8c8e](https://github.com/nek0der/weir/commit/baf8c8ef0268feb757584e3170144d2b87b931ea))
* **updates:** let the badge for an installed update clear itself after five seconds ([#367](https://github.com/nek0der/weir/issues/367)) ([efdf393](https://github.com/nek0der/weir/commit/efdf3930dd4f2997da5661b09aa2f33becd756a0))
* **worktree:** keep each worktree's identity when two share a branch, and drop stale pull request lookups ([#365](https://github.com/nek0der/weir/issues/365)) ([abba7a7](https://github.com/nek0der/weir/commit/abba7a7d954aad408c9760226b6e1e17a9d1c3c2))
* **worktree:** keep only the end of Git's output, and read both of its streams in turn ([#373](https://github.com/nek0der/weir/issues/373)) ([b7bdc4e](https://github.com/nek0der/weir/commit/b7bdc4ee65325695869050e9cd1e60de15eb07a0))


### Performance

* **review:** convert long text selections to diff lines in linear time ([#377](https://github.com/nek0der/weir/issues/377)) ([b08e021](https://github.com/nek0der/weir/commit/b08e021d0376f57c972138444858373c2e476df5))
* **review:** save file read marks off the main actor, and write a burst of them once ([#378](https://github.com/nek0der/weir/issues/378)) ([c694d05](https://github.com/nek0der/weir/commit/c694d05b9ce1df2d53206652953d308338d3fb5d))


### Documentation

* **site:** retake the README's hero image and the site's captures so they match the current app ([#393](https://github.com/nek0der/weir/issues/393)) ([43f31a4](https://github.com/nek0der/weir/commit/43f31a47dcb820943c0175bcb7ec04fb9b05751f))

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

## [0.1.17](https://github.com/nek0der/weir/compare/v0.1.16...v0.1.17) (2026-11-03)


### Features

* **palette:** add rows for new agent tabs and each Settings section, and let a check post keys ([#298](https://github.com/nek0der/weir/issues/298)) ([c3e09b8](https://github.com/nek0der/weir/commit/c3e09b890f67629e585ab11afc6bf7c6a85b9c8a))
* **supervision:** list only installed agents in the + menu and the plan usage panel ([#295](https://github.com/nek0der/weir/issues/295)) ([dbea4b5](https://github.com/nek0der/weir/commit/dbea4b5029a10b235b702f4a2eb8ffa7433cc249))


### Bug Fixes

* **agent:** keep Weir's hooks when Claude is given --settings, and ignore the test overrides inside the app ([#291](https://github.com/nek0der/weir/issues/291)) ([f502194](https://github.com/nek0der/weir/commit/f5021940294389ef2a31053b8991e4651bf43343))
* **approval:** keep one decision per request through a dropped connection and a quit ([#293](https://github.com/nek0der/weir/issues/293)) ([3e1d3f7](https://github.com/nek0der/weir/commit/3e1d3f73b5b431b8d5969c73a4d30712586c365e))
* **l10n:** end the Japanese for folder and editor in a long vowel, and reword three strings ([#286](https://github.com/nek0der/weir/issues/286)) ([4360e50](https://github.com/nek0der/weir/commit/4360e5005cfc654a7cc4d0fb0e4b0d188fe32a97))
* **notifications:** release the wake observer and the rate limiter's spent keys ([#288](https://github.com/nek0der/weir/issues/288)) ([2290833](https://github.com/nek0der/weir/commit/2290833da2a2fb654de7eb1a144098191a9d16d6))
* **surface:** tell libghostty when a modifier or the right button is released, or the pointer leaves a pane ([#292](https://github.com/nek0der/weir/issues/292)) ([6246b9a](https://github.com/nek0der/weir/commit/6246b9afb62381550977820f91a69697a5531dfb))
* **tmux:** keep an agent in tmux shown on its pane, and show agents in nested tmux ([#294](https://github.com/nek0der/weir/issues/294)) ([d0f8000](https://github.com/nek0der/weir/commit/d0f800096dccbb561cc154a85cef5df5548fad25))
* **updates:** answer Check for Updates during an update, and package only a notarized app with a known version ([#287](https://github.com/nek0der/weir/issues/287)) ([07de39f](https://github.com/nek0der/weir/commit/07de39ffecd59b06f13beb1a6552b0fae55be92d))


### Documentation

* **adr:** limit each ADR to its decision, and correct the documents that no longer match the code ([#296](https://github.com/nek0der/weir/issues/296)) ([f06094d](https://github.com/nek0der/weir/commit/f06094da66df726e1897ae3c1c08d43959777eff))

## [0.1.16](https://github.com/nek0der/weir/compare/v0.1.15...v0.1.16) (2026-11-03)


### Features

* **agent:** hold an approval until it is answered, wherever its pane is ([#257](https://github.com/nek0der/weir/issues/257)) ([caca087](https://github.com/nek0der/weir/commit/caca087478abe33f89d5e5dd762c59c5f20d6b92))
* **agent:** support the Antigravity CLI ([#247](https://github.com/nek0der/weir/issues/247)) ([88ed5d4](https://github.com/nek0der/weir/commit/88ed5d457a1d8669ff7df9a24232443bd62235ff))
* **agent:** support the OpenCode CLI ([#259](https://github.com/nek0der/weir/issues/259)) ([bc6f84b](https://github.com/nek0der/weir/commit/bc6f84bd238e6100e0fde5145f7568d5a3192641))
* **keyboard:** show each control's key while Command is held, and tidy the default keys ([#236](https://github.com/nek0der/weir/issues/236)) ([0df0223](https://github.com/nek0der/weir/commit/0df0223d6d679bfe5acaae7e740dde0e3a9b248e))
* **supervision:** always open a new window from New Window, and let ⌘-click open one from the sidebar ([#263](https://github.com/nek0der/weir/issues/263)) ([ffe60fc](https://github.com/nek0der/weir/commit/ffe60fc046fcd52e3ea6c1e06a30ad87b9ca004c))


### Bug Fixes

* **agent:** bring a reopened tab's conversations back with it ([#256](https://github.com/nek0der/weir/issues/256)) ([6fecc90](https://github.com/nek0der/weir/commit/6fecc90d8d7af1799c7cf751d70ab6f764bbb160))
* **agent:** leave a run record this build cannot read untouched, and sweep the files no record needs ([#276](https://github.com/nek0der/weir/issues/276)) ([2a9ba20](https://github.com/nek0der/weir/commit/2a9ba20591941b82beb92060a1a150bb8d7a858d))
* **agent:** read the turns before a restore takes the lock, and expire undo records that can no longer apply ([#266](https://github.com/nek0der/weir/issues/266)) ([a3665c2](https://github.com/nek0der/weir/commit/a3665c2318a204933c2213c86e72ddcde0003c67))
* **agent:** record the changes of the turn that OpenCode's --prompt starts ([#281](https://github.com/nek0der/weir/issues/281)) ([5e702d8](https://github.com/nek0der/weir/commit/5e702d830bfdad278fa6c385c0b7afc6a4504033))
* **agent:** show a resumed Codex as idle, and stop resuming conversations that were quit ([#255](https://github.com/nek0der/weir/issues/255)) ([d14a4dc](https://github.com/nek0der/weir/commit/d14a4dcb1ed3db814ed8623c05cb899c320738c5))
* **agent:** stop a shim running itself when the PATH names it another way ([#248](https://github.com/nek0der/weir/issues/248)) ([e82af5d](https://github.com/nek0der/weir/commit/e82af5db8eadc3c06759df2183efc21576452548))
* **agent:** stop making a routed worktree before the agent's permission checks ([#253](https://github.com/nek0der/weir/issues/253)) ([b3e7188](https://github.com/nek0der/weir/commit/b3e71889a545948ecc1dd77a1db3e0a069f9b51c))
* **confirmations:** ask before a close or quit ends an agent that has not reported yet ([#272](https://github.com/nek0der/weir/issues/272)) ([cbc69d2](https://github.com/nek0der/weir/commit/cbc69d24b28685336880e296f762d11610ab03c3))
* **demo:** keep demo commands out of the contributor's shell history ([#280](https://github.com/nek0der/weir/issues/280)) ([36643a5](https://github.com/nek0der/weir/commit/36643a57c1c62f49d707759a4725be1fa5040bda))
* **keyboard:** give shortcuts of the same length the same width ([#258](https://github.com/nek0der/weir/issues/258)) ([107ef41](https://github.com/nek0der/weir/commit/107ef41ce6146129134807f377cec11c153e3135))
* **keyboard:** give the pane the keyboard back when Esc closes the palette or search ([#244](https://github.com/nek0der/weir/issues/244)) ([61beaa3](https://github.com/nek0der/weir/commit/61beaa31cce76e22fc124538aaf795bd2fda58cc))
* **keyboard:** refuse shortcuts on keys that type or that a standard menu holds, and stop stored ones breaking the config ([#271](https://github.com/nek0der/weir/issues/271)) ([9d1c7cb](https://github.com/nek0der/weir/commit/9d1c7cbd81f122171d7eda142d7637f8fae60ba2))
* **palette:** run the highlighted row, match every subsequence, and send Find to the review while it is in front ([#273](https://github.com/nek0der/weir/issues/273)) ([ccb19e5](https://github.com/nek0der/weir/commit/ccb19e5152c506e0f20b62f04fab605075135e25))
* **review:** keep the file list when a name is not UTF-8, read modes from the lines that carry them, and show changes without relying on color ([#270](https://github.com/nek0der/weir/issues/270)) ([93f68a8](https://github.com/nek0der/weir/commit/93f68a82394f70b7e49758ef60a074307dc349cf))
* **review:** keep the review open when an insert cannot be recorded, and refuse a duplicate insert or one into an exited pane ([#277](https://github.com/nek0der/weir/issues/277)) ([9f14c8d](https://github.com/nek0der/weir/commit/9f14c8d2ac36f2e54484439281d9142c9f776a2c))
* **session:** keep the session through an unknown agent state and bound the autosave delay ([#265](https://github.com/nek0der/weir/issues/265)) ([ce21279](https://github.com/nek0der/weir/commit/ce212790fea78dc9e8cb1ec93592378b1d8b0e7e))
* **settings:** pick up a save in place, and keep a file that stops decoding ([#239](https://github.com/nek0der/weir/issues/239)) ([eb39b62](https://github.com/nek0der/weir/commit/eb39b6276aaa724d8de7db221eb162eea36df8e4))
* **supervision:** draw one line where the frames of two panes meet ([#260](https://github.com/nek0der/weir/issues/260)) ([0fe4064](https://github.com/nek0der/weir/commit/0fe406425868b46f5eb00b127acae30aab475c94))
* **supervision:** give each conversation one row in the review's scope menu, and stop long lines widening menus ([#238](https://github.com/nek0der/weir/issues/238)) ([f4604af](https://github.com/nek0der/weir/commit/f4604af2b8d2eb6a0808a2fc304a6146fd133411))
* **supervision:** give the floating panels one margin, and keep the rail's panels within the surfaces ([#245](https://github.com/nek0der/weir/issues/245)) ([7648da7](https://github.com/nek0der/weir/commit/7648da7ca1dbfbd4e4b518b1e098363d26a7c29d))
* **supervision:** keep the focus where it was when another pane closes ([#274](https://github.com/nek0der/weir/issues/274)) ([a8024f0](https://github.com/nek0der/weir/commit/a8024f013686ce4aa2e1acbcb895a4964611c05d))
* **supervision:** keep the title bar's names and field readable when names are long or the window is narrow ([#241](https://github.com/nek0der/weir/issues/241)) ([771553f](https://github.com/nek0der/weir/commit/771553f3341481dc8242decf3f70ab7c1d29c60d))
* **supervision:** line the approval card up with the surfaces, and drop its arrow ([#243](https://github.com/nek0der/weir/issues/243)) ([d79cbd6](https://github.com/nek0der/weir/commit/d79cbd6845800fef354052bab74a73072a23bfc8))
* **supervision:** open the approval card next to what opened it, and say on the decision bar where to answer ([#284](https://github.com/nek0der/weir/issues/284)) ([261a347](https://github.com/nek0der/weir/commit/261a347efb73b9428643187cd9a87adf2bc78bad))
* **supervision:** say when a project's folder or git is unavailable ([#279](https://github.com/nek0der/weir/issues/279)) ([d869b74](https://github.com/nek0der/weir/commit/d869b747df2c5e55bfccb51b3d778eee032eb404))
* **supervision:** show Codex's badge in black on white, like its logo ([#261](https://github.com/nek0der/weir/issues/261)) ([547a087](https://github.com/nek0der/weir/commit/547a08722088bac780a65b8ce692d0f9f7b29e4c))
* **supervision:** show the decision bar's count first in its row, between ‹ and › buttons ([#275](https://github.com/nek0der/weir/issues/275)) ([f0e1635](https://github.com/nek0der/weir/commit/f0e1635a8c25dd8d89ad596d47c713f72d4ffc9a))
* **supervision:** stand the approval card beside the Needs Attention list, and give the review's bars room ([#237](https://github.com/nek0der/weir/issues/237)) ([d694b53](https://github.com/nek0der/weir/commit/d694b531d1fa3d61e5586241c7dd74d87cc66bad))
* **supervision:** stop a long folder cutting off the pane's name in the status band, and show the folder a shell is in ([#262](https://github.com/nek0der/weir/issues/262)) ([bc704f5](https://github.com/nek0der/weir/commit/bc704f59dce2e59bd47e3b04cfcf927e4bedc033))
* **supervision:** stop a waiting pane showing its mark twice, and Answer touching a row's badges ([#233](https://github.com/nek0der/weir/issues/233)) ([afa7b63](https://github.com/nek0der/weir/commit/afa7b63d55cae2fad04d982582962b943525b34c))
* **supervision:** tint a conversation's tab and cards on hover instead of outlining them ([#254](https://github.com/nek0der/weir/issues/254)) ([947cd7b](https://github.com/nek0der/weir/commit/947cd7bfb1e30e1057108fb767d1f7094458595f))
* **surface:** create a pane's terminal once, and show a clearer Retry card only while the terminal has failed to start ([#278](https://github.com/nek0der/weir/issues/278)) ([26c4867](https://github.com/nek0der/weir/commit/26c4867181ae70f1f9244f73e7ef9611e078e32b))
* **worktree:** stop marking all worktrees missing when git refuses to list them ([#264](https://github.com/nek0der/weir/issues/264)) ([71369da](https://github.com/nek0der/weir/commit/71369da465affddbdf690d5878e1625d8150cb11))


### Refactors

* **agent:** list each agent once, so adding one cannot miss a place ([#282](https://github.com/nek0der/weir/issues/282)) ([e1140f1](https://github.com/nek0der/weir/commit/e1140f1a47f1b7e7743a5ab9dcb82441814650e9))
* **core:** stop Core importing AppKit and SwiftUI ([#250](https://github.com/nek0der/weir/issues/250)) ([19e762b](https://github.com/nek0der/weir/commit/19e762b05bebd345ad631353e8cca77ff25e357a))
* **core:** stop Core naming the UI type SurfaceView ([#242](https://github.com/nek0der/weir/issues/242)) ([aae0688](https://github.com/nek0der/weir/commit/aae06889b99b021d7b20a9ce0baf633673521e9d))
* **supervision:** hand the menu bar, All Projects, and changes panel actions only the stores they use ([#252](https://github.com/nek0der/weir/issues/252)) ([ec5d074](https://github.com/nek0der/weir/commit/ec5d074c05a303df78fe124d214cd07ce40bced9))
* **supervision:** move the restore and window actions from UI to App ([#251](https://github.com/nek0der/weir/issues/251)) ([089f501](https://github.com/nek0der/weir/commit/089f501e15b611bf299486947b89d52fc830d9b4))


### Documentation

* **readme:** rewrite the README around the site, and add a Japanese version ([#249](https://github.com/nek0der/weir/issues/249)) ([46ff1ba](https://github.com/nek0der/weir/commit/46ff1ba137dc583bcf32cb88a26c04a7e7a75fb2))
* **site:** give the keys the app uses, and correct the documents and comments that no longer match the code ([#267](https://github.com/nek0der/weir/issues/267)) ([0d94e93](https://github.com/nek0der/weir/commit/0d94e931668114fc3886d21ecd3f4a65c09b4e7c))
* **site:** write the documents in English and Japanese ([#235](https://github.com/nek0der/weir/issues/235)) ([fce2a55](https://github.com/nek0der/weir/commit/fce2a55b99262b76ca7add01bf1b23c8aa4ec7b8))

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

## [0.1.14](https://github.com/nek0der/weir/compare/v0.1.13...v0.1.14) (2026-10-31)


### Features

* **agent:** show the actions Claude's auto mode refused on each turn's Changes card ([#189](https://github.com/nek0der/weir/issues/189)) ([a6b2a26](https://github.com/nek0der/weir/commit/a6b2a26bf4cd20b21786b7b5e881836f2049d45f))
* **app:** add a weir command that opens a folder from the terminal ([#215](https://github.com/nek0der/weir/issues/215)) ([58b44fd](https://github.com/nek0der/weir/commit/58b44fdf4d525d61ba5bfde06880ae693722dfad))
* **app:** rename the app from Limpid to Weir, and give it a new icon ([#210](https://github.com/nek0der/weir/issues/210)) ([cb5d827](https://github.com/nek0der/weir/commit/cb5d827c8d6248feff408ff5adffe7689a8dd457))
* **notifications:** lead each history row with what it is about, and frame each source's rows as one group ([#193](https://github.com/nek0der/weir/issues/193)) ([b7fea13](https://github.com/nek0der/weir/commit/b7fea13dcf140ccafdcc951b7acab37b82496d77))
* **sidebar:** drag a tab or pane onto any project's row, and give every pane a header ([#195](https://github.com/nek0der/weir/issues/195)) ([2e6ffa7](https://github.com/nek0der/weir/commit/2e6ffa7a09302e1bab0ceca386ebe4ed0a13e5f9))
* **sidebar:** keep a project's header in sight while its rows scroll, and reorder projects on a layer over the list ([#197](https://github.com/nek0der/weir/issues/197)) ([b818dca](https://github.com/nek0der/weir/commit/b818dca3d4fc8ec7519169bd938f13252689967d))
* **sidebar:** look up a row's pull request as an agent's turn ends, and check open ones more often ([#198](https://github.com/nek0der/weir/issues/198)) ([c56fa8d](https://github.com/nek0der/weir/commit/c56fa8dedb358c8c86c0f910b7e1c924db0c7c21))
* **sidebar:** put the repository's row first with a tag, and say each row's Git counts and time with their units ([#188](https://github.com/nek0der/weir/issues/188)) ([482bfbf](https://github.com/nek0der/weir/commit/482bfbf017d44f13cee541ffc6d4ff3e7bf4e2c1))
* **supervision:** replace the Changes panel's viewed-turns button with a plain line that opens once ([#185](https://github.com/nek0der/weir/issues/185)) ([eb28c70](https://github.com/nek0der/weir/commit/eb28c70e29b28dffd18856d7078eea0394bb672c))
* **supervision:** show each agent pane's model and permission mode in its header, and warn when it runs without asking ([#187](https://github.com/nek0der/weir/issues/187)) ([baaeca3](https://github.com/nek0der/weir/commit/baaeca3586f6dbb8b66dc3ec37dccb9b867b811b))
* **supervision:** show each agent's effort and tokens in its pane header, and the worktree's tokens in the Changes panel ([#207](https://github.com/nek0der/weir/issues/207)) ([14e89cb](https://github.com/nek0der/weir/commit/14e89cbebd9a260b595eb5690eb518db9286a496))
* **supervision:** show every agent on a row and a tab, and mark each pane with its agent's badge ([#199](https://github.com/nek0der/weir/issues/199)) ([d65dcc6](https://github.com/nek0der/weir/commit/d65dcc6db4ee4f8cdf0fbe3012656ade70f6ee4f))


### Bug Fixes

* **agent:** end a stop, and the decision bar lines set during it, when the person starts another conversation in its pane ([#181](https://github.com/nek0der/weir/issues/181)) ([5ce4ee1](https://github.com/nek0der/weir/commit/5ce4ee141e6cf2384a16036f6eca5bd92f345574))
* **agent:** lift a provider's usage limit once another of its runs finishes a turn after the stop ([#183](https://github.com/nek0der/weir/issues/183)) ([417ad08](https://github.com/nek0der/weir/commit/417ad085a386712b12339100fac2c97c0f3522bc))
* **approval:** end a request left to the terminal once its agent's session ends ([#184](https://github.com/nek0der/weir/issues/184)) ([05af190](https://github.com/nek0der/weir/commit/05af1905ac969278fff0414671f96c5133482715))
* **codex:** take the session's folder from where Codex runs the hook, now that a tool's cwd is the folder the tool runs in ([#186](https://github.com/nek0der/weir/issues/186)) ([378d9bc](https://github.com/nek0der/weir/commit/378d9bc752bc668b05154d1ee0975c55556c5555))
* **design:** stop an inline rename's text moving 2pt as its edit opens on macOS 27.2 ([#191](https://github.com/nek0der/weir/issues/191)) ([be0bac4](https://github.com/nek0der/weir/commit/be0bac4b73f29569eb94566c217740860b62f42b))
* **design:** stop the running arc in All Projects drifting out of place as it turns ([#192](https://github.com/nek0der/weir/issues/192)) ([67d250f](https://github.com/nek0der/weir/commit/67d250fc221667bd09c45bbc9a8c9ee698789fc0))
* **notifications:** keep the macOS notification notice's button neutral on its amber band ([#203](https://github.com/nek0der/weir/issues/203)) ([747ac9a](https://github.com/nek0der/weir/commit/747ac9afdbc43794b9bf6923c54ebece7d945d17))
* **notifications:** stop a selected history row drawing a second frame inside its group's ([#205](https://github.com/nek0der/weir/issues/205)) ([21b46ba](https://github.com/nek0der/weir/commit/21b46ba2e0780a7ca48e90318ebe2ddbcc9a35b2))
* **sidebar:** show the scratch row's agents and state instead of a fixed mark ([#208](https://github.com/nek0der/weir/issues/208)) ([a07eea8](https://github.com/nek0der/weir/commit/a07eea8aaaec5e029ff9929be8316f3d339fe9e2))
* **supervision:** draw a pane's attention frame around its header and decision bar ([#202](https://github.com/nek0der/weir/issues/202)) ([26812b5](https://github.com/nek0der/weir/commit/26812b5156be121d249354fdc968f5e169fc59db))
* **supervision:** stop a pane counting as seen after its window moves to a row with no tabs ([#211](https://github.com/nek0der/weir/issues/211)) ([5acca2d](https://github.com/nek0der/weir/commit/5acca2d163e457ebc5bd2db8da65e051d7f3352d))
* **supervision:** stop the highlight of the pane strip's add button running into the rule ([#204](https://github.com/nek0der/weir/issues/204)) ([21794f2](https://github.com/nek0der/weir/commit/21794f2af540b7013857caae0a0d55518e78bad1))
* **supervision:** stop the menu bar window's buttons and lit row standing out of its glass ([#213](https://github.com/nek0der/weir/issues/213)) ([8b240a1](https://github.com/nek0der/weir/commit/8b240a11f629caa248c4773e74c964f1cefe19c8))
* **supervision:** take a pane header's model and permission mode from the agent the pane shows, and keep a split's warning in sight ([#194](https://github.com/nek0der/weir/issues/194)) ([c168ac0](https://github.com/nek0der/weir/commit/c168ac0f56a8dab1a5aa727b6be07f8c54282249))

## [0.1.13](https://github.com/nek0der/limpid/compare/v0.1.12...v0.1.13) (2026-10-29)


### Features

* **agent:** show an MCP server's request for input under Claude Code with its words, from its Elicitation hook ([#176](https://github.com/nek0der/limpid/issues/176)) ([8c6cfd2](https://github.com/nek0der/limpid/commit/8c6cfd292056bd42f713552687a98805a3e3bc37))
* **sidebar:** name each row by its branch, and make a name the person gives a label beside it ([#179](https://github.com/nek0der/limpid/issues/179)) ([ded379e](https://github.com/nek0der/limpid/commit/ded379ec514f9e7572a0b2cbaa28c9fe94f5dc74))

## [0.1.12](https://github.com/nek0der/limpid/compare/v0.1.11...v0.1.12) (2026-10-29)


### Features

* **agent:** show an agent waiting on an MCP server's question or a sign-in, which only its terminal status report says ([#173](https://github.com/nek0der/limpid/issues/173)) ([8a41545](https://github.com/nek0der/limpid/commit/8a41545354d4fef510c6d4cb078ce6ccff5c7d31))
* **sidebar:** fold missing worktrees under their own line and let the Ready to Clean Up line delete its worktrees ([#165](https://github.com/nek0der/limpid/issues/165)) ([090e05f](https://github.com/nek0der/limpid/commit/090e05fc0df5451d24961f75fccb0053ad8ba704))
* **supervision:** show each agent's plan usage in a panel from the rail ([#171](https://github.com/nek0der/limpid/issues/171)) ([5b8fd80](https://github.com/nek0der/limpid/commit/5b8fd80a2b921d8e574ad81e2c02eb3867cc6941))
* **supervision:** show the shells and subagents Claude leaves running after a turn ([#161](https://github.com/nek0der/limpid/issues/161)) ([20340cf](https://github.com/nek0der/limpid/commit/20340cfe819c05b37186078b4764c184db8e754a))
* **supervision:** tell agent conversations apart by name and color, and group the Changes panel's turns by conversation ([#167](https://github.com/nek0der/limpid/issues/167)) ([cbc7aac](https://github.com/nek0der/limpid/commit/cbc7aace3a316c64dea7ceb781d0f8f3e70dd22d))


### Bug Fixes

* **agent:** keep a Claude pane finished when a background subagent's tool call ends ([#164](https://github.com/nek0der/limpid/issues/164)) ([8954c0a](https://github.com/nek0der/limpid/commit/8954c0af56c5a8ce706a11b40f6d671e6cb81f16))
* **codex:** record the turns Codex begins for a /goal from their start, with the goal as their prompt ([#172](https://github.com/nek0der/limpid/issues/172)) ([859773b](https://github.com/nek0der/limpid/commit/859773bab8861fe4705d45fe8648deb103804a30))
* **codex:** run Limpid's hooks whatever CODEX_HOME is, and stop writing to ~/.codex/config.toml ([#168](https://github.com/nek0der/limpid/issues/168)) ([d5a8d9d](https://github.com/nek0der/limpid/commit/d5a8d9d78e81bc7115658fe9c8720cf36225f48a))
* **notifications:** fit the macOS notification notice on one line ([#166](https://github.com/nek0der/limpid/issues/166)) ([675cd9f](https://github.com/nek0der/limpid/commit/675cd9ffa2f32cbbc8afcaed641ccb92be42fa7e))
* **worktree:** stop waiting on killed processes launchd has not reaped, and fix the Windows replay test ([#174](https://github.com/nek0der/limpid/issues/174)) ([dedffb9](https://github.com/nek0der/limpid/commit/dedffb9c20fbdaeee572eb8ef3eb21702a739985))


### Refactors

* **agent:** stop reading hook fields neither Claude Code nor Codex sends ([#169](https://github.com/nek0der/limpid/issues/169)) ([e6bafa9](https://github.com/nek0der/limpid/commit/e6bafa9dfce991997d42953cf494f094a02a33b5))


### Documentation

* **agent:** describe when Claude Code sends its idle prompt, which it holds back while a subagent runs ([#170](https://github.com/nek0der/limpid/issues/170)) ([297af67](https://github.com/nek0der/limpid/commit/297af67793df1c7a5aec5512e8806e4f49bacc5b))

## [0.1.11](https://github.com/nek0der/limpid/compare/v0.1.10...v0.1.11) (2026-10-28)


### Features

* **agent:** name a tab by the title Codex gives its session and by Claude's /rename ([#156](https://github.com/nek0der/limpid/issues/156)) ([1e6a282](https://github.com/nek0der/limpid/commit/1e6a2823261b693e983dce4ca8d08fc048f49b92))
* **sidebar:** title the sidebar "Projects" and open a folder from its + ([#146](https://github.com/nek0der/limpid/issues/146)) ([14d7f98](https://github.com/nek0der/limpid/commit/14d7f98a9668505bbfbc8de901504f7b419caddf))
* **supervision:** list the session's tabs to search and switch from the pane strip ([#144](https://github.com/nek0der/limpid/issues/144)) ([cb8391e](https://github.com/nek0der/limpid/commit/cb8391e7ed8c4e88485377b0a4898486116fda20))
* **supervision:** show each turn's tokens and test runs on its Changes card ([#151](https://github.com/nek0der/limpid/issues/151)) ([ebb828a](https://github.com/nek0der/limpid/commit/ebb828a0330d331ad2f2e3f853af49d6eb629e01))
* **supervision:** show the agent's last reply on each turn's Changes card and notification ([#160](https://github.com/nek0der/limpid/issues/160)) ([e4dcff3](https://github.com/nek0der/limpid/commit/e4dcff312141eaac8082a56e89eb1edb32424df1))


### Bug Fixes

* **agent:** end a Claude turn stopped with Esc or Ctrl+C right away ([#155](https://github.com/nek0der/limpid/issues/155)) ([1e12443](https://github.com/nek0der/limpid/commit/1e124431c16cfdeec5470eb72acd032962a897e3))
* **approval:** clear an approval refused in Claude's own dialog right away ([#149](https://github.com/nek0der/limpid/issues/149)) ([831ab00](https://github.com/nek0der/limpid/commit/831ab00992936247dc1e5058350efee7eabda1a4))
* **codex:** count the tokens of a Codex turn's subagents ([#158](https://github.com/nek0der/limpid/issues/158)) ([942c325](https://github.com/nek0der/limpid/commit/942c32581ccd212481501b34b7482f7c89366424))
* **codex:** show "Needs answer" while Codex waits on a question ([#154](https://github.com/nek0der/limpid/issues/154)) ([5523c59](https://github.com/nek0der/limpid/commit/5523c5937cef4a461e8e62f0c839d183695cfd11))
* **codex:** show any failed Codex turn as failed, not only one at the usage limit ([#159](https://github.com/nek0der/limpid/issues/159)) ([77a2c00](https://github.com/nek0der/limpid/commit/77a2c00a0b44d3c4059c69df2b4cf6fb0721868e))
* **codex:** show the tokens and test runs of a Codex turn stopped with Esc ([#157](https://github.com/nek0der/limpid/issues/157)) ([85c6918](https://github.com/nek0der/limpid/commit/85c6918b27fe68a10d5064b8e7f7150f5d6625f8))
* **sidebar:** move the project-wide worktree entries from each row's menu to the project header ([#147](https://github.com/nek0der/limpid/issues/147)) ([d8efef3](https://github.com/nek0der/limpid/commit/d8efef3db8fd7fe98d4ed856f82af25fa4aa1924))
* **supervision:** show a row and a pane header as running while an earlier turn is unread ([#152](https://github.com/nek0der/limpid/issues/152)) ([8c5a1e1](https://github.com/nek0der/limpid/commit/8c5a1e1d328045b111a24b2652872e1dd16e3c57))
* **surface:** save a pane's scrollback while a full-screen program runs in it ([#150](https://github.com/nek0der/limpid/issues/150)) ([5d17765](https://github.com/nek0der/limpid/commit/5d17765e2e452a814a9f182e341f2d919cb65c62))

## [0.1.10](https://github.com/nek0der/limpid/compare/v0.1.9...v0.1.10) (2026-10-23)


### Features

* **agent:** warn when Claude's prompt cache has expired ([#122](https://github.com/nek0der/limpid/issues/122)) ([a7f1247](https://github.com/nek0der/limpid/commit/a7f124754d573d7cf5ded2e2ecf99ed9a4db43b2))
* **keyboard:** show shortcuts beside items in Limpid's menus ([#126](https://github.com/nek0der/limpid/issues/126)) ([3c43fa4](https://github.com/nek0der/limpid/commit/3c43fa4b781a24d9a9c94f38e6ffaffe2125f814))
* **sidebar:** show the color picker in Limpid's floating panel ([#123](https://github.com/nek0der/limpid/issues/123)) ([f67f784](https://github.com/nek0der/limpid/commit/f67f784ef786f66ca3fb2a5a0f593579ce6265b4))
* **supervision:** rebuild the main window for supervising coding agents ([#130](https://github.com/nek0der/limpid/issues/130)) ([7fe2e59](https://github.com/nek0der/limpid/commit/7fe2e596a3acb30a83f88446513e17ae248e0e36))
* **surface:** keep the pane header while zoomed, and zoom from the terminal menu ([#125](https://github.com/nek0der/limpid/issues/125)) ([ba64946](https://github.com/nek0der/limpid/commit/ba6494672acb9b617b039e384665cff92e13de46))
* **surface:** show a header on each pane of a split tab ([#120](https://github.com/nek0der/limpid/issues/120)) ([ac6f4ec](https://github.com/nek0der/limpid/commit/ac6f4ec8c17b73ee808912744ab53d71b284db41))


### Bug Fixes

* **notices:** ship the license texts of everything the app links or bundles ([#128](https://github.com/nek0der/limpid/issues/128)) ([8bb5150](https://github.com/nek0der/limpid/commit/8bb51508696d37e3310f5fa3c4a7970cd5b633b5))
* **settings:** switch every in-app string with the display language ([#127](https://github.com/nek0der/limpid/issues/127)) ([2b15658](https://github.com/nek0der/limpid/commit/2b15658a2cadf7b02147fc64262757da37799aba))


### Refactors

* **surface:** host the pane rename panel on the shared floating panel ([#124](https://github.com/nek0der/limpid/issues/124)) ([b33f12f](https://github.com/nek0der/limpid/commit/b33f12fa2ea07c18712c6b47a5be1d4e24755230))

## [0.1.9](https://github.com/nek0der/limpid/compare/v0.1.8...v0.1.9) (2026-10-02)


### Bug Fixes

* **approval:** clear answered questions from Waiting ([#117](https://github.com/nek0der/limpid/issues/117)) ([3c4f195](https://github.com/nek0der/limpid/commit/3c4f19588d9fe77ef4792c482be9976213756e17))
* **keyboard:** forward Control+Enter to the terminal ([#119](https://github.com/nek0der/limpid/issues/119)) ([36e1ed0](https://github.com/nek0der/limpid/commit/36e1ed07c98756caa7b11ace542022f15f0f3739))

## [0.1.8](https://github.com/nek0der/limpid/compare/v0.1.7...v0.1.8) (2026-09-30)


### Features

* **review:** open a diff line in the editor ([#102](https://github.com/nek0der/limpid/issues/102)) ([36683b2](https://github.com/nek0der/limpid/commit/36683b21baeac6f7029296a2ae5cfa54e788932f))
* **surface:** open terminal file paths in the editor at the line ([#95](https://github.com/nek0der/limpid/issues/95)) ([a94433a](https://github.com/nek0der/limpid/commit/a94433a9c7589f73adaf16570b9eb85d687b359e))


### Bug Fixes

* **codex:** treat any LIMPID_DEMO value as demo mode ([#92](https://github.com/nek0der/limpid/issues/92)) ([b5a55b5](https://github.com/nek0der/limpid/commit/b5a55b5ee87b7c2783871169f01f44a1c3088798))
* **demo:** mask the hostname with localhost so panes keep their working directory ([#96](https://github.com/nek0der/limpid/issues/96)) ([b6e9ebf](https://github.com/nek0der/limpid/commit/b6e9ebfb7184c2f71e0a0860e403259a6e783076))
* **glass:** give floating panels one material surface ([#88](https://github.com/nek0der/limpid/issues/88)) ([36719cc](https://github.com/nek0der/limpid/commit/36719cc5ef2d9d0b23158fae94865474eca21c16))
* **keyboard:** fire menu shortcuts bound to function keys ([#108](https://github.com/nek0der/limpid/issues/108)) ([9422a86](https://github.com/nek0der/limpid/commit/9422a865968a297e2e149ed4b494d411421da671))
* **notifications:** show 99+ in both unread badges ([#91](https://github.com/nek0der/limpid/issues/91)) ([0546593](https://github.com/nek0der/limpid/commit/0546593338b80e21ee09dff95ba13ddc97331c8b))
* **palette:** abbreviate home paths the way the sheets do ([#90](https://github.com/nek0der/limpid/issues/90)) ([ea681b6](https://github.com/nek0der/limpid/commit/ea681b6dc494fadc205a4f5ba689c6fd8f168b1d))
* **palette:** open a recent project into a tab, as the sidebar does ([#111](https://github.com/nek0der/limpid/issues/111)) ([884825c](https://github.com/nek0der/limpid/commit/884825cf4d8c9244dc6728bf5521100f5e65b8f0))
* **review:** align the docked terminal's rows with the tab ([#86](https://github.com/nek0der/limpid/issues/86)) ([23969d0](https://github.com/nek0der/limpid/commit/23969d02c4b636679992b6cc4acc8f31877d5aab))
* **review:** unmark comments from a refused paste with no window open ([#100](https://github.com/nek0der/limpid/issues/100)) ([84bc945](https://github.com/nek0der/limpid/commit/84bc9458cb40d31a13a3c2fa2e92df07c895540b))
* **surface:** check terminal link targets before opening them ([#89](https://github.com/nek0der/limpid/issues/89)) ([35862d8](https://github.com/nek0der/limpid/commit/35862d8e8b5df96c911ffc5f1321ad6e36b26407))
* **worktree:** keep bootstrap commands and paths out of public logs ([#93](https://github.com/nek0der/limpid/issues/93)) ([8f90c09](https://github.com/nek0der/limpid/commit/8f90c09debedb90ba419f31d2a8170b4b707af7e))


### Refactors

* **agent:** centralize agent file layout ([#113](https://github.com/nek0der/limpid/issues/113)) ([6e692d1](https://github.com/nek0der/limpid/commit/6e692d1475b01287188b052fdf7ba6becb5fe6a9))
* **agent:** name run record files in one place ([#110](https://github.com/nek0der/limpid/issues/110)) ([e11bb8e](https://github.com/nek0der/limpid/commit/e11bb8e0e82b652606f9fbad432564b02b93a233))
* **confirmations:** keep the close and quit alert behind the policy gates ([#107](https://github.com/nek0der/limpid/issues/107)) ([a6772e1](https://github.com/nek0der/limpid/commit/a6772e112ea2f876554f398e9d3cea59b91d4930))
* **design:** drop unused tokens and modifiers ([#103](https://github.com/nek0der/limpid/issues/103)) ([48a696d](https://github.com/nek0der/limpid/commit/48a696d80b12a4f8ee29f4d4261cf11c90a99e5b))
* **design:** extract shared UI components ([#112](https://github.com/nek0der/limpid/issues/112)) ([cea4663](https://github.com/nek0der/limpid/commit/cea46637312742d9dd81c007bb862ee995d9d3ee))
* **ghostty:** route binding actions through GhosttyFFI ([#94](https://github.com/nek0der/limpid/issues/94)) ([22355f8](https://github.com/nek0der/limpid/commit/22355f88eb1c670af84867d6972765b49202c346))
* **keyboard:** read named keys from one table ([#106](https://github.com/nek0der/limpid/issues/106)) ([ec9858c](https://github.com/nek0der/limpid/commit/ec9858c5b75a3135b7efa32cd76e7f2bfccc1e30))
* **layout:** share the pane fit check between splits and edge drops ([#105](https://github.com/nek0der/limpid/issues/105)) ([5dddbba](https://github.com/nek0der/limpid/commit/5dddbbadb090a7f8e2f786c9ecb84bef04e009bc))
* **persistence:** move unreadable files aside in one place ([#104](https://github.com/nek0der/limpid/issues/104)) ([d34d080](https://github.com/nek0der/limpid/commit/d34d080902be606fc8404fe9bac41233d7a91cab))
* **session:** keep persisted layout defaults and timings in Core ([#99](https://github.com/nek0der/limpid/issues/99)) ([9d56889](https://github.com/nek0der/limpid/commit/9d568895afe5be6a10069aa099e2e99a1af7c93a))
* **settings:** build the settings file URL in one place ([#109](https://github.com/nek0der/limpid/issues/109)) ([589634d](https://github.com/nek0der/limpid/commit/589634df6756649b403d9fbcd0f6ae34ab90dde5))
* **settings:** move SettingsStore into Core ([#97](https://github.com/nek0der/limpid/issues/97)) ([4470306](https://github.com/nek0der/limpid/commit/4470306fd16f08ecf2b09e450a3d905c46739796))
* **updates:** keep window markers and the update menu item out of Core ([#98](https://github.com/nek0der/limpid/issues/98)) ([e5e2581](https://github.com/nek0der/limpid/commit/e5e2581bcff7f38c84bba872aa98e26e8f936212))

## [0.1.7](https://github.com/nek0der/limpid/compare/v0.1.6...v0.1.7) (2026-09-29)


### Features

* **agent:** move the agent lifecycle projection to Rust ([#71](https://github.com/nek0der/limpid/issues/71)) ([1b19655](https://github.com/nek0der/limpid/commit/1b196554fc8d967ada27f89650bf5afc9ab9840e))
* **approval:** answer AskUserQuestion from the approval card ([#81](https://github.com/nek0der/limpid/issues/81)) ([58aa312](https://github.com/nek0der/limpid/commit/58aa312bc2e08d8a6f7c6aab474356e25b68c7b3))
* **keyboard:** add a keyboard shortcut cheat sheet ([#80](https://github.com/nek0der/limpid/issues/80)) ([091c517](https://github.com/nek0der/limpid/commit/091c5179532ddf23ef2173fec9c051bf652b0d9e))
* **quick-terminal:** add a quick terminal toggled by a global hotkey ([#79](https://github.com/nek0der/limpid/issues/79)) ([80ffe5b](https://github.com/nek0der/limpid/commit/80ffe5b21267e05e924f0ebaa7d528c667c201fa))
* **settings:** align the Settings window with System Settings ([#82](https://github.com/nek0der/limpid/issues/82)) ([7b83f40](https://github.com/nek0der/limpid/commit/7b83f40caa9f9e6660223576c880f008e0cdb576))


### Bug Fixes

* **approval:** skip the alert in ad-hoc builds and let Debug sign with a Team ID ([#83](https://github.com/nek0der/limpid/issues/83)) ([5f5d5b8](https://github.com/nek0der/limpid/commit/5f5d5b8de22f7dde0cb9bc897003ac908074d8c4))
* **layout:** keep toolbar controls in place ([#84](https://github.com/nek0der/limpid/issues/84)) ([9847a13](https://github.com/nek0der/limpid/commit/9847a1330d4a3a470741faab6d677b340a83699a))
* **palette:** evict frecency entries that have decayed to nothing ([#75](https://github.com/nek0der/limpid/issues/75)) ([fa9e2d9](https://github.com/nek0der/limpid/commit/fa9e2d9f24259fa3f98aed2b0fc9fafb32e281e1))


### Performance

* **agent:** stop idle wakeups and redundant sidebar work ([#74](https://github.com/nek0der/limpid/issues/74)) ([1f9e8cf](https://github.com/nek0der/limpid/commit/1f9e8cf8f2c82752a2cb1db702b23931b735286e))


### Documentation

* **ghostty:** add libghostty fork maintenance rules ([#76](https://github.com/nek0der/limpid/issues/76)) ([558d98c](https://github.com/nek0der/limpid/commit/558d98c5ccf95d35b648f9d364543e93fc4f6601))

## [0.1.6](https://github.com/nek0der/limpid/compare/v0.1.5...v0.1.6) (2026-09-14)


### Features

* **agent:** move hook lifecycle processing into Rust ([#67](https://github.com/nek0der/limpid/issues/67)) ([485250e](https://github.com/nek0der/limpid/commit/485250eb30e73e664207b1bfd41ffb093bca53fe))


### Bug Fixes

* **approval:** register the approval service on first install ([#70](https://github.com/nek0der/limpid/issues/70)) ([75ff985](https://github.com/nek0der/limpid/commit/75ff985f42da8cda9234e1b832ebd827c2038c65))

## [0.1.5](https://github.com/nek0der/limpid/compare/v0.1.4...v0.1.5) (2026-09-13)


### Features

* **approval:** add native agent approvals ([#61](https://github.com/nek0der/limpid/issues/61)) ([58d3aae](https://github.com/nek0der/limpid/commit/58d3aaeaba0bfc26f57ced1593d6b84a16c41505))
* **approval:** enable native approvals in Release builds ([#65](https://github.com/nek0der/limpid/issues/65)) ([70d6b74](https://github.com/nek0der/limpid/commit/70d6b747d28884c9cb471f91b29b4c345144da8b))
* **claude:** use session titles for tabs ([#54](https://github.com/nek0der/limpid/issues/54)) ([e68ffae](https://github.com/nek0der/limpid/commit/e68ffae23be41971bb071f7ff77ec9f5eb7cdfe9))
* **review:** add turn-scoped review ([#59](https://github.com/nek0der/limpid/issues/59)) ([5221a7f](https://github.com/nek0der/limpid/commit/5221a7f3744da45117e94881cc81dd9d68630fc7))
* **review:** rebuild the header around the insert destination ([#62](https://github.com/nek0der/limpid/issues/62)) ([75f3c43](https://github.com/nek0der/limpid/commit/75f3c43dc180f2d1d6a4d45aa08474ee073f124d))


### Bug Fixes

* **notifications:** distinguish viewed agent completions ([#64](https://github.com/nek0der/limpid/issues/64)) ([8f649d7](https://github.com/nek0der/limpid/commit/8f649d7fabba8010ddaa4f36edc3789ed03efff9))
* **worktree:** allow forced removal with submodules ([#63](https://github.com/nek0der/limpid/issues/63)) ([887e55b](https://github.com/nek0der/limpid/commit/887e55ba4175454c4460355377ee7b6e51aabfc9))


### Refactors

* **codex:** route tab titles through Rust ([#56](https://github.com/nek0der/limpid/issues/56)) ([fdca8ca](https://github.com/nek0der/limpid/commit/fdca8cab21a10d56e656a81fa676cce8c915daab))

## [0.1.4](https://github.com/nek0der/limpid/compare/v0.1.3...v0.1.4) (2026-09-12)


### Features

* **notifications:** align Waiting with notification history ([#48](https://github.com/nek0der/limpid/issues/48)) ([8e8691f](https://github.com/nek0der/limpid/commit/8e8691f1b06fbdd23f225a353da1b6f5f86e92ba))
* **review:** highlight intraline changes ([#44](https://github.com/nek0der/limpid/issues/44)) ([8c333d7](https://github.com/nek0der/limpid/commit/8c333d70e0366fdc33a4080e5cf6a89fbb27a0a5))
* **review:** improve diff inspection and file actions ([#42](https://github.com/nek0der/limpid/issues/42)) ([e00b308](https://github.com/nek0der/limpid/commit/e00b308130e69561e7e9a3084b8129ecc0c190c2))
* **settings:** add settings search ([#45](https://github.com/nek0der/limpid/issues/45)) ([ca8195c](https://github.com/nek0der/limpid/commit/ca8195cfa53000353781abb22c3ecbad75651d67))


### Bug Fixes

* **layout:** correct cursor styles across the interface ([#49](https://github.com/nek0der/limpid/issues/49)) ([d0d8ff2](https://github.com/nek0der/limpid/commit/d0d8ff2cf00218cab25ad7185e0e54fad5707260))
* **layout:** make column dividers easier to grab ([#43](https://github.com/nek0der/limpid/issues/43)) ([620460e](https://github.com/nek0der/limpid/commit/620460e8b15be0906b66b8c42709ad4dadf9485e))
* **layout:** stabilize pane sizing and search overlays ([#50](https://github.com/nek0der/limpid/issues/50)) ([031627a](https://github.com/nek0der/limpid/commit/031627a7e97bdecefc5c1350a8c1787e3cf91263))
* **layout:** stabilize sidebar transitions ([#47](https://github.com/nek0der/limpid/issues/47)) ([a8a5e64](https://github.com/nek0der/limpid/commit/a8a5e645e1e7a25b92ef8d8ea3e30619c6403b06))
* **surface:** keep startup commands out of tab titles ([#40](https://github.com/nek0der/limpid/issues/40)) ([a8a41ca](https://github.com/nek0der/limpid/commit/a8a41ca52c3f333fe28355ce9da9106a4fb55908))
* **updates:** avoid deprecated Sparkle appcast initializer ([#46](https://github.com/nek0der/limpid/issues/46)) ([a076c41](https://github.com/nek0der/limpid/commit/a076c41ab900c518d9950fa668038b00a3da178b))

## [0.1.3](https://github.com/nek0der/limpid/compare/v0.1.2...v0.1.3) (2026-09-11)


### Features

* **surface:** show terminal scroll position ([#36](https://github.com/nek0der/limpid/issues/36)) ([1609603](https://github.com/nek0der/limpid/commit/16096035c70d89517768e6739ab1c51b7ec0518d))


### Bug Fixes

* **codex:** test hooks against the selected Codex executable ([#35](https://github.com/nek0der/limpid/issues/35)) ([4bd9e58](https://github.com/nek0der/limpid/commit/4bd9e587117e6d3dbe7eb279d68a002225ef94d5))
* **config:** honor bell choices and stop emitting invalid settings ([#31](https://github.com/nek0der/limpid/issues/31)) ([8933cca](https://github.com/nek0der/limpid/commit/8933cca25e90cda9c75a4ef81e0a5de9e5ec7a43))
* **config:** report Ghostty errors and honor scrollback line limits ([#30](https://github.com/nek0der/limpid/issues/30)) ([da79391](https://github.com/nek0der/limpid/commit/da79391142c10bc83d0f85b0e071eda770341fdc))
* **glass:** remove shadows from glass surfaces ([#29](https://github.com/nek0der/limpid/issues/29)) ([5c84a31](https://github.com/nek0der/limpid/commit/5c84a31b7c651226b20a03078a122363411c7d92))
* **layout:** keep narrow windows usable ([#39](https://github.com/nek0der/limpid/issues/39)) ([df790be](https://github.com/nek0der/limpid/commit/df790be16635e9810c2c92605b6c60b085678a82))
* **surface:** enable Secure Keyboard Entry for local password prompts ([#32](https://github.com/nek0der/limpid/issues/32)) ([4bea63a](https://github.com/nek0der/limpid/commit/4bea63ae0166232950e2ffe2e3b48f51a215f993))
* **surface:** expose xterm-ghostty capabilities to terminal programs ([#34](https://github.com/nek0der/limpid/issues/34)) ([9820ddb](https://github.com/nek0der/limpid/commit/9820ddbc5088093c9c27797c219cff7d6040c327))
* **surface:** honor Option-as-Alt and input source changes ([#37](https://github.com/nek0der/limpid/issues/37)) ([253c5ba](https://github.com/nek0der/limpid/commit/253c5bacf18c8e5e7e0e186b073fab16aef01b29))
* **surface:** report the active color scheme to terminal programs ([#33](https://github.com/nek0der/limpid/issues/33)) ([9fca8c8](https://github.com/nek0der/limpid/commit/9fca8c86a66fd35d2ab93f7cd0b8c0fd72f469b3))
* **tmux:** follow agent state through tmux-hosted panes and shared shims ([#27](https://github.com/nek0der/limpid/issues/27)) ([4f19797](https://github.com/nek0der/limpid/commit/4f1979735c646227a572f187bfecd100428b7072))

## [0.1.2](https://github.com/nek0der/limpid/compare/v0.1.1...v0.1.2) (2026-09-08)


### Features

* **review:** comment on a diff and hand the notes to the agent below ([#25](https://github.com/nek0der/limpid/issues/25)) ([4930b39](https://github.com/nek0der/limpid/commit/4930b3923232b75c11a52d478c6f3637154afde7))
* **sidebar:** drop the floating card and reach the window edges ([#26](https://github.com/nek0der/limpid/issues/26)) ([12f9f3a](https://github.com/nek0der/limpid/commit/12f9f3aa524cbf818f13014d38498ee32ffd9abc))
* **sidebar:** show a row's linked pull request ([#13](https://github.com/nek0der/limpid/issues/13)) ([c1037b1](https://github.com/nek0der/limpid/commit/c1037b1d9178aa9a9f086be76dc95bb5054d141e))
* **tmux:** host agent panes in tmux so they outlive a quit ([#24](https://github.com/nek0der/limpid/issues/24)) ([863d073](https://github.com/nek0der/limpid/commit/863d073fc4b1bb6c09e619934664680ee485b0af))
* **tmux:** reattach a pane to the session it was showing ([#21](https://github.com/nek0der/limpid/issues/21)) ([4931139](https://github.com/nek0der/limpid/commit/493113949950ddfe44017032d8beb0aac93daa6b))


### Bug Fixes

* **claude:** merge a user-supplied --settings rather than losing to it ([#17](https://github.com/nek0der/limpid/issues/17)) ([ca98a5c](https://github.com/nek0der/limpid/commit/ca98a5cb83a98b265ad58fe10b801d6e65019f51))
* **codex:** update agent state on interrupted turns and session exit ([#16](https://github.com/nek0der/limpid/issues/16)) ([7d8cc39](https://github.com/nek0der/limpid/commit/7d8cc39ccaee20cb2b5d89e340438af54972b362))
* **entitlements:** allow microphone and Apple Events requests ([#20](https://github.com/nek0der/limpid/issues/20)) ([08da440](https://github.com/nek0der/limpid/commit/08da44080a352099a9819ccc54a0915151dcfc62))
* **sidebar:** accept tab drops on the last container row ([#10](https://github.com/nek0der/limpid/issues/10)) ([48f52ac](https://github.com/nek0der/limpid/commit/48f52acf9ec25cef6cfc8c58d0ce4ee0389dd822))
* **surface:** send input method commits as key events, not pastes ([#22](https://github.com/nek0der/limpid/issues/22)) ([90e494d](https://github.com/nek0der/limpid/commit/90e494dc5250d50eb108f1ac501224470735ffdc))
* **surface:** unblock dictation in a terminal pane ([#18](https://github.com/nek0der/limpid/issues/18)) ([5f857fb](https://github.com/nek0der/limpid/commit/5f857fbfad2d6b4b9a405b7d26548bf7e9588b8c))


### Refactors

* **codex:** retire the shadow CODEX_HOME for command-line hooks ([#19](https://github.com/nek0der/limpid/issues/19)) ([6a37768](https://github.com/nek0der/limpid/commit/6a377686ecf5902072339f1587078b9a58caa430))
* **session:** drop the unread tab-count cache ([#14](https://github.com/nek0der/limpid/issues/14)) ([95d3112](https://github.com/nek0der/limpid/commit/95d31126640f119a18bf1e8398134e99a80e1ed4))

## [0.1.1](https://github.com/nek0der/limpid/compare/v0.1.0...v0.1.1) (2026-06-09)


### Bug Fixes

* **surface:** sync layer scale on display switch ([#3](https://github.com/nek0der/limpid/issues/3)) ([22993e6](https://github.com/nek0der/limpid/commit/22993e6c7ec503b284ec35491e3b6d0d886de5e9))


### CI

* **dependabot:** drop the unusable swift ecosystem ([0d1a329](https://github.com/nek0der/limpid/commit/0d1a3294f4b779bd06e280c9d051090befa00e2f))
