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

## What's Changed
* build(app): skip unused App Intents metadata extraction by @nek0der in https://github.com/nek0der/weir/pull/359
* fix(supervision): keep a moved pane's own folder and the focus when the pane to split has closed by @nek0der in https://github.com/nek0der/weir/pull/360
* fix(agent): keep plan usage when one value is out of range, and keep a turn's passed check by @nek0der in https://github.com/nek0der/weir/pull/363
* fix(review): search the files Find's note names, and keep each line's hunk header in a stacked file by @nek0der in https://github.com/nek0der/weir/pull/361
* fix(agent): stop late reports from replacing a pane's newer agent or stop, and keep a reopened tab's run by @nek0der in https://github.com/nek0der/weir/pull/364
* fix(worktree): keep each worktree's identity when two share a branch, and drop stale pull request lookups by @nek0der in https://github.com/nek0der/weir/pull/365
* fix(notifications): show a dash for an unusable duration, and keep the history entry that holds it by @nek0der in https://github.com/nek0der/weir/pull/366
* fix(updates): let the badge for an installed update clear itself after five seconds by @nek0der in https://github.com/nek0der/weir/pull/367
* fix(demo): use the default time of day when the demo clock names an invalid one by @nek0der in https://github.com/nek0der/weir/pull/368
* fix(design): darken three light conversation colors so each mark stands out on a hovered row by @nek0der in https://github.com/nek0der/weir/pull/369
* test(support): consolidate overlapping tests and strengthen regression checks by @nek0der in https://github.com/nek0der/weir/pull/370
* fix(claude): stop taking a tool result for a turn's prompt, so a cut-off count reads as partial by @nek0der in https://github.com/nek0der/weir/pull/371
* fix(agent): read the exported login PATH, and keep glob characters literal in shims by @nek0der in https://github.com/nek0der/weir/pull/376
* fix(review): stop a swapped path from reading a file outside the worktree or stalling the read by @nek0der in https://github.com/nek0der/weir/pull/372
* perf(review): save file read marks off the main actor, and write a burst of them once by @nek0der in https://github.com/nek0der/weir/pull/378
* fix(surface): keep a closed pane's late callbacks from reaching a new pane by @nek0der in https://github.com/nek0der/weir/pull/374
* fix(review): cap the diffs Find keeps by their measured text bytes and rows by @nek0der in https://github.com/nek0der/weir/pull/379
* fix(worktree): keep only the end of Git's output, and read both of its streams in turn by @nek0der in https://github.com/nek0der/weir/pull/373
* fix(agent): keep a restore's writes inside the worktree when a folder is replaced by a link by @nek0der in https://github.com/nek0der/weir/pull/375
* fix(demo): stop marking every demo project Folder Missing, so the fixture's counts show by @nek0der in https://github.com/nek0der/weir/pull/383
* perf(review): convert long text selections to diff lines in linear time by @nek0der in https://github.com/nek0der/weir/pull/377
* fix(review): show newlines in file and folder names as symbols, so no name is cut short by @nek0der in https://github.com/nek0der/weir/pull/380
* fix(agent): tell apart folder changes within one second, so a later worktree move is still suggested by @nek0der in https://github.com/nek0der/weir/pull/384
* fix(sidebar): line up the project headers' marks and counts, and show an icon for another window by @nek0der in https://github.com/nek0der/weir/pull/382
* fix(app): report pull request, editor, and terminal configuration failures by @nek0der in https://github.com/nek0der/weir/pull/381
* fix(approval): release XPC waits synchronously, and keep test process cleanup bounded by @nek0der in https://github.com/nek0der/weir/pull/386
* fix(core): keep throttles and cache expiry right when the system clock moves by @nek0der in https://github.com/nek0der/weir/pull/385
* fix(sidebar): show a project's trouble as an icon in the count slot, so its name keeps its room by @nek0der in https://github.com/nek0der/weir/pull/387
* fix(supervision): keep pane titles readable in splits, and show warnings as icons by @nek0der in https://github.com/nek0der/weir/pull/388
* fix(supervision): show project activity and usage limits as icons so names keep their room by @nek0der in https://github.com/nek0der/weir/pull/389
* fix(review): keep file paths readable with compact marks and conversation tags by @nek0der in https://github.com/nek0der/weir/pull/390
* fix(design): give each state and command one icon and one color across the app by @nek0der in https://github.com/nek0der/weir/pull/391
* fix(supervision): open the menu bar's Needs Attention list through accessibility presses by @nek0der in https://github.com/nek0der/weir/pull/392
* docs(site): retake the README's hero image and the site's captures so they match the current app by @nek0der in https://github.com/nek0der/weir/pull/393
* chore(main): release 0.1.19 by @nek0der in https://github.com/nek0der/weir/pull/362


**Full Changelog**: https://github.com/nek0der/weir/compare/v0.1.18...v0.1.19

<!-- weir-source-commit: 5119bfb6d8ea5e78d295b6db7c29eaefc7c14ff9 -->
