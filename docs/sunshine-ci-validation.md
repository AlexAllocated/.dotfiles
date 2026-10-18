# Sunshine fork CI validation

## 2026-09-07 investigation

Keep the audio feature PR narrow. Fork publishing/setup failures are not audio test
failures and should not be fixed by borrowing upstream credentials or adding unrelated
workflow changes to the feature.

- Run `34183655205`: both Windows architectures compiled, then failed
  `ExternalAudioTest.DisabledModePreservesDefaultFallback`. The test inspected the
  controller's fake enumerator, while the WASAPI capture object creates its own.
  Corrected the test to use the existing capture-selection test hook. Production
  behavior did not change. Replacement native run: `34187088526`.
- Lint run `34187089622`: CI uses clang-format **23.1.0**; local clang-format 21.1.8
  had reformatted an unrelated loop's closing parenthesis. Restored upstream's
  formatting and validated all four changed C++ files with the exact CI formatter:
  `uvx --from clang-format==23.1.0 clang-format --dry-run --Werror ...`.
- Pages run `34187089624`: `Setup Pages` fails because the fork has no configured
  GitHub Pages site. This is not the configuration documentation build failing.
- Full CI run `34187089805`: Copr package setup targets upstream's publishing
  infrastructure without its secrets; the command fails before compilation.
  Homebrew macOS 15 reports all formula checks passed, then fails uploading missing
  coverage/test-result artifacts. Do not describe either as a passing native audio
  suite or as an audio regression.

The review branch remains one commit. The separate personal build workflow is not
part of the PR. Installed Sunshine remains pinned to the earlier verified artifact;
review/test-only changes do not require interrupting the working installation.

These notes record observed failures, not final status of reruns. Check GitHub for
completion before upstream submission. Main Output graph work in AMPS is separate.

## Verified rerun results

- Native run `34187088526` completed successfully on Windows x64 and ARM64:
  **608 tests passed on each**, including the corrected default-fallback test.
- Lint run `34187935377` completed successfully after matching clang-format 23.1.0.
- Build source is `98b24e1c4843b5f132b8589d80a508eae09b9fa6`; review source is
  `ee9144461d9cb2e1fa00122b763044731f1daacc`. Besides the personal workflow,
  the only difference is the unrelated loop formatting required by CI. No executable
  behavior differs between these two revisions.
- The older full CI run's Docker conclusion failed because its build jobs were
  cancelled by the replacement run, not because a Docker compilation failed.
- Alex agreed upstream-resource checks can wait for the upstream PR.
