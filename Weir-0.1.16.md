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

## What's Changed
* fix(site): keep the footer above the gesture bar, and center the story as the browser's bars move by @nek0der in https://github.com/nek0der/weir/pull/230
* chore(deps): bump github/codeql-action/init from 4.39.0 to 4.39.1 by @dependabot[bot] in https://github.com/nek0der/weir/pull/231
* chore(deps): bump github/codeql-action/analyze from 4.39.0 to 4.39.1 by @dependabot[bot] in https://github.com/nek0der/weir/pull/232
* fix(supervision): stop a waiting pane showing its mark twice, and Answer touching a row's badges by @nek0der in https://github.com/nek0der/weir/pull/233
* docs(site): write the documents in English and Japanese by @nek0der in https://github.com/nek0der/weir/pull/235
* fix(supervision): stand the approval card beside the Needs Attention list, and give the review's bars room by @nek0der in https://github.com/nek0der/weir/pull/237
* feat(keyboard): show each control's key while Command is held, and tidy the default keys by @nek0der in https://github.com/nek0der/weir/pull/236
* fix(supervision): give each conversation one row in the review's scope menu, and stop long lines widening menus by @nek0der in https://github.com/nek0der/weir/pull/238
* fix(settings): pick up a save in place, and keep a file that stops decoding by @nek0der in https://github.com/nek0der/weir/pull/239
* chore(site): capture the documents' screenshots with make site-images by @nek0der in https://github.com/nek0der/weir/pull/240
* fix(supervision): keep the title bar's names and field readable when names are long or the window is narrow by @nek0der in https://github.com/nek0der/weir/pull/241
* fix(keyboard): give the pane the keyboard back when Esc closes the palette or search by @nek0der in https://github.com/nek0der/weir/pull/244
* fix(supervision): line the approval card up with the surfaces, and drop its arrow by @nek0der in https://github.com/nek0der/weir/pull/243
* refactor(core): stop Core naming the UI type SurfaceView by @nek0der in https://github.com/nek0der/weir/pull/242
* fix(supervision): give the floating panels one margin, and keep the rail's panels within the surfaces by @nek0der in https://github.com/nek0der/weir/pull/245
* chore(site): show the review on the landing page, and retake the captures by @nek0der in https://github.com/nek0der/weir/pull/246
* feat(agent): support the Antigravity CLI by @nek0der in https://github.com/nek0der/weir/pull/247
* fix(agent): stop a shim running itself when the PATH names it another way by @nek0der in https://github.com/nek0der/weir/pull/248
* docs(readme): rewrite the README around the site, and add a Japanese version by @nek0der in https://github.com/nek0der/weir/pull/249
* refactor(core): stop Core importing AppKit and SwiftUI by @nek0der in https://github.com/nek0der/weir/pull/250
* refactor(supervision): move the restore and window actions from UI to App by @nek0der in https://github.com/nek0der/weir/pull/251
* refactor(supervision): hand the menu bar, All Projects, and changes panel actions only the stores they use by @nek0der in https://github.com/nek0der/weir/pull/252
* fix(agent): stop making a routed worktree before the agent's permission checks by @nek0der in https://github.com/nek0der/weir/pull/253
* fix(agent): show a resumed Codex as idle, and stop resuming conversations that were quit by @nek0der in https://github.com/nek0der/weir/pull/255
* fix(agent): bring a reopened tab's conversations back with it by @nek0der in https://github.com/nek0der/weir/pull/256
* fix(supervision): tint a conversation's tab and cards on hover instead of outlining them by @nek0der in https://github.com/nek0der/weir/pull/254
* feat(agent): hold an approval until it is answered, wherever its pane is by @nek0der in https://github.com/nek0der/weir/pull/257
* fix(keyboard): give shortcuts of the same length the same width by @nek0der in https://github.com/nek0der/weir/pull/258
* feat(agent): support the OpenCode CLI by @nek0der in https://github.com/nek0der/weir/pull/259
* fix(supervision): draw one line where the frames of two panes meet by @nek0der in https://github.com/nek0der/weir/pull/260
* fix(supervision): show Codex's badge in black on white, like its logo by @nek0der in https://github.com/nek0der/weir/pull/261
* feat(supervision): always open a new window from New Window, and let ⌘-click open one from the sidebar by @nek0der in https://github.com/nek0der/weir/pull/263
* fix(worktree): stop marking all worktrees missing when git refuses to list them by @nek0der in https://github.com/nek0der/weir/pull/264
* fix(supervision): stop a long folder cutting off the pane's name in the status band, and show the folder a shell is in by @nek0der in https://github.com/nek0der/weir/pull/262
* fix(session): keep the session through an unknown agent state and bound the autosave delay by @nek0der in https://github.com/nek0der/weir/pull/265
* docs(site): give the keys the app uses, and correct the documents and comments that no longer match the code by @nek0der in https://github.com/nek0der/weir/pull/267
* fix(agent): read the turns before a restore takes the lock, and expire undo records that can no longer apply by @nek0der in https://github.com/nek0der/weir/pull/266
* test(support): run the tests in a bare host that never comes to the front by @nek0der in https://github.com/nek0der/weir/pull/268
* chore(build): pin Xcode, put time limits on the CI jobs, and auto-merge only GitHub Actions updates by @nek0der in https://github.com/nek0der/weir/pull/269
* fix(review): keep the file list when a name is not UTF-8, read modes from the lines that carry them, and show changes without relying on color by @nek0der in https://github.com/nek0der/weir/pull/270
* fix(keyboard): refuse shortcuts on keys that type or that a standard menu holds, and stop stored ones breaking the config by @nek0der in https://github.com/nek0der/weir/pull/271
* fix(confirmations): ask before a close or quit ends an agent that has not reported yet by @nek0der in https://github.com/nek0der/weir/pull/272
* fix(palette): run the highlighted row, match every subsequence, and send Find to the review while it is in front by @nek0der in https://github.com/nek0der/weir/pull/273
* fix(supervision): keep the focus where it was when another pane closes by @nek0der in https://github.com/nek0der/weir/pull/274
* fix(supervision): show the decision bar's count first in its row, between ‹ and › buttons by @nek0der in https://github.com/nek0der/weir/pull/275
* fix(agent): leave a run record this build cannot read untouched, and sweep the files no record needs by @nek0der in https://github.com/nek0der/weir/pull/276
* fix(review): keep the review open when an insert cannot be recorded, and refuse a duplicate insert or one into an exited pane by @nek0der in https://github.com/nek0der/weir/pull/277
* fix(surface): create a pane's terminal once, and show a clearer Retry card only while the terminal has failed to start by @nek0der in https://github.com/nek0der/weir/pull/278
* fix(supervision): say when a project's folder or git is unavailable by @nek0der in https://github.com/nek0der/weir/pull/279
* fix(demo): keep demo commands out of the contributor's shell history by @nek0der in https://github.com/nek0der/weir/pull/280
* fix(agent): record the changes of the turn that OpenCode's --prompt starts by @nek0der in https://github.com/nek0der/weir/pull/281
* refactor(agent): list each agent once, so adding one cannot miss a place by @nek0der in https://github.com/nek0der/weir/pull/282
* test(support): let an agent check a running Debug build without taking over the screen by @nek0der in https://github.com/nek0der/weir/pull/283
* fix(supervision): open the approval card next to what opened it, and say on the decision bar where to answer by @nek0der in https://github.com/nek0der/weir/pull/284
* chore(main): release 0.1.16 by @nek0der in https://github.com/nek0der/weir/pull/234


**Full Changelog**: https://github.com/nek0der/weir/compare/v0.1.15...v0.1.16

<!-- weir-source-commit: 807c2188c89e3be0e68450d108a190f054f04daa -->
