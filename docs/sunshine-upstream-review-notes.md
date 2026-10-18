# Sunshine upstream review notes

Research date: 2026-09-07 (America/Denver). Read-only upstream research; no PR or
issue was submitted or edited as part of this review.

## Sample and limitations

Reviewed descriptions, available review summaries, conversation comments, and
selected human inline feedback from eight merged PRs. Selection emphasized audio,
platform boundaries, small configuration features, and recent maintainer work.
Dependency-bot updates were excluded from the sample. This is a qualitative sample,
not an estimate of acceptance rates. A merged PR with no public human feedback does
not establish that its implementation or presentation was considered ideal.

| PR                                                                                         | Why it matters                                  | Observed lesson                                                                                                                                                              |
| ------------------------------------------------------------------------------------------ | ----------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [5408: Windows configured-sink capture](https://github.com/LizardByte/Sunshine/pull/5408)  | Direct predecessor                              | Explicitly preserved default switching for compatibility; described native testing and limitations; disclosed heavy AI use. No public inline review comments were returned.  |
| [5125: Steam audio driver installation](https://github.com/LizardByte/Sunshine/pull/5125)  | Same Windows audio file                         | Very small fix; maintainer discussed architecture limits and suggested a concrete macro correction.                                                                          |
| [4261: continuous audio](https://github.com/LizardByte/Sunshine/pull/4261)                 | Audio behavior option                           | Review clarified whether the client or host owns the setting and considered bandwidth cost. Later discussion raised an underrun concern; merging is not proof of perfection. |
| [4209: macOS Tap API](https://github.com/LizardByte/Sunshine/pull/4209)                    | Substantial audio feature with extensive review | Questions covered option necessity, real-device testing, callback safety, multichannel behavior, host muting, portable builds, and test failures.                            |
| [5465: client-name environment variable](https://github.com/LizardByte/Sunshine/pull/5465) | Small user-facing addition                      | Explained a specific scripting use case and included results from two actual clients; received approval.                                                                     |
| [5629: PipeWire pacing](https://github.com/LizardByte/Sunshine/pull/5629)                  | Recent capture-path feature                     | Maintainer explicitly requested a lint correction; author explained a related refactor and offered to split its scope.                                                       |
| [5621: macOS microphone permission flow](https://github.com/LizardByte/Sunshine/pull/5621) | Platform-specific failure states                | Description lists permission states and unit coverage; no public human review discussion was returned.                                                                       |
| [5602: pairing refactor and comments](https://github.com/LizardByte/Sunshine/pull/5602)    | Current maintainer conventions                  | Description emphasizes testable helpers and state transitions; includes comment/documentation cleanup rather than a preference for comment-free code.                        |

## Concrete feedback to learn from

- **Explain why a setting is necessary.** The reviewer questioned the new setting in
  [4209](https://github.com/LizardByte/Sunshine/pull/4209#discussion_r2312235092).
  Our answer: retaining existing default-device behavior while opting into an
  external mixer's ownership, not introducing another equivalent sink selector.
- **Respect client semantics.** Review discussed host mute behavior in
  [4209](https://github.com/LizardByte/Sunshine/pull/4209#discussion_r2312243202)
  and clarified client ownership in
  [4261](https://github.com/LizardByte/Sunshine/pull/4261#issuecomment-3392882701).
  Our deliberate host-playback override deserves prominent explanation.
- **Keep tests portable and failures contained.** Review requested platform-specific
  test placement and warned that a crashing test takes down the entire suite:
  [test placement](https://github.com/LizardByte/Sunshine/pull/4209#discussion_r2760526179),
  [crash containment](https://github.com/LizardByte/Sunshine/pull/4209#discussion_r2760536559).
- **Fix concrete quality findings; do not cargo-cult them.** There are explicit
  [lint requests](https://github.com/LizardByte/Sunshine/pull/5629#issuecomment-5560836261)
  and a precise [Windows macro suggestion](https://github.com/LizardByte/Sunshine/pull/5125#discussion_r3251541385).
  Bot output is not interchangeable with maintainer judgment.
- **Readable documentation is expected.** Review requested short lines and direct
  configuration links, and allowed replacing bulky explanatory material with a
  reference: [documentation](https://github.com/LizardByte/Sunshine/pull/4209#discussion_r2883918071),
  [comment simplification](https://github.com/LizardByte/Sunshine/pull/4209#discussion_r2883938017).
  This supports concise useful comments, not removing all comments.

## Presentation and policy

The current [contribution guide](https://docs.lizardbyte.dev/latest/developers/contributing.html)
requires the official template, including its comments and sections. Use a
conventional title, fill only applicable checklist items, and describe the change
in the contributor's own words. Upstream squash-merges accepted PRs; our single
commit is tidy but not a demonstrated prerequisite for review. Several sampled
merged PRs retained multiple development commits.

The inherited [official template](https://github.com/LizardByte/.github/blob/master/.github/pull_request_template.md)
has an explicit AI-usage checklist. Our work fits Heavy, not None or Light.
The [maintainer response on 4209](https://github.com/LizardByte/Sunshine/pull/4209#issuecomment-3238299722)
expressly says disclosed AI involvement was not itself a blocker. This is evidence
against trying to make the contribution appear unassisted, not a guarantee of
acceptance. Human understanding, review, and testing still matter.

## Gaps in our draft before upstream submission

Assessment of fork PR #1 at source revision
`e3a6b2f47ff296d11bbdc15431db61f0582224e9`:

1. **Template:** current fork description is a review memo, not the official
   submission template. Alex should put his description into the official
   structure, preserving its comments/checklists. Do not mark self-review complete
   on Alex's behalf.
2. **Use case:** lead with external mixer ownership in general. AMPS is a tested
   example, not a dependency or upstream requirement. Omit dotfiles reconciliation
   details from the main implementation description.
3. **Compatibility rationale:** explain that #5408 intentionally retained default
   switching; our default-off option preserves that policy for existing users.
   Do not imply the predecessor was incomplete or incorrect.
4. **Screenshot:** attach the new Windows Audio/Video checkbox and its help text.
5. **Testing precision:** distinguish native unit tests, mocked browser checks, and
   actual Windows/Moonlight stereo playback. The current tested artifact is the
   pre-squash build revision `a07bf4c56eda88f9fe88470788b59d543786e4f4`;
   the later source change removed comments only. Rebuild/test the exact final
   source before presenting it as the tested submission, or state this distinction.
6. **Remaining matrix:** explicitly verify disabled-mode compatibility, host-playback
   both ways, disconnect/reconnect, a missing or unplugged configured endpoint, and
   surround-format behavior. Existing fake-endpoint tests cover several failures,
   but they do not prove real-device hotplug/recovery or 5.1/7.1 playback. Avoid
   claiming those hardware cases have already passed.
7. **Failure-test robustness:** some new guards are exercised using a controller
   without initialized policy interfaces. A guard regression could crash rather
   than produce an ordinary assertion failure. Consider a fake policy interface or
   isolated test approach; this is a review risk, not an observed production bug.
8. **Comment accuracy:** the existing comment above `requested_sink` still says the
   assigned sink is preferred, whereas external mode deliberately prefers the
   configured sink. Update that stale comment rather than adding broad narration.
9. **Scope:** keep personal packaging and Windows deployment out of this PR. Do not
   claim to close the Linux-only request. Preserve the new option's default-off
   behavior, explicit endpoint requirement, and documented playback consequences.

These are recommendations from the research, not changes already made to the PR.
No live Sunshine or AMPS configuration was changed during this review.
