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

## What's Changed
* chore(build): move the macOS jobs to Xcode 27.1 on the xcode-27 runner, and fix the new warnings by @nek0der in https://github.com/nek0der/weir/pull/285
* fix(l10n): end the Japanese for folder and editor in a long vowel, and reword three strings by @nek0der in https://github.com/nek0der/weir/pull/286
* fix(updates): answer Check for Updates during an update, and package only a notarized app with a known version by @nek0der in https://github.com/nek0der/weir/pull/287
* fix(notifications): release the wake observer and the rate limiter's spent keys by @nek0der in https://github.com/nek0der/weir/pull/288
* chore(build): let make clean remove only this checkout's DerivedData, not every worktree's by @nek0der in https://github.com/nek0der/weir/pull/290
* fix(agent): keep Weir's hooks when Claude is given --settings, and ignore the test overrides inside the app by @nek0der in https://github.com/nek0der/weir/pull/291
* fix(surface): tell libghostty when a modifier or the right button is released, or the pointer leaves a pane by @nek0der in https://github.com/nek0der/weir/pull/292
* fix(approval): keep one decision per request through a dropped connection and a quit by @nek0der in https://github.com/nek0der/weir/pull/293
* feat(supervision): list only installed agents in the + menu and the plan usage panel by @nek0der in https://github.com/nek0der/weir/pull/295
* test(agent): keep the hook's timing tests from racing the alias's start and a truncating write by @nek0der in https://github.com/nek0der/weir/pull/297
* docs(adr): limit each ADR to its decision, and correct the documents that no longer match the code by @nek0der in https://github.com/nek0der/weir/pull/296
* feat(palette): add rows for new agent tabs and each Settings section, and let a check post keys by @nek0der in https://github.com/nek0der/weir/pull/298
* fix(tmux): keep an agent in tmux shown on its pane, and show agents in nested tmux by @nek0der in https://github.com/nek0der/weir/pull/294
* chore(main): release 0.1.17 by @nek0der in https://github.com/nek0der/weir/pull/289


**Full Changelog**: https://github.com/nek0der/weir/compare/v0.1.16...v0.1.17

<!-- weir-source-commit: 4df2840b1b48cbec22f54224d3a65671e7bf0ff0 -->
