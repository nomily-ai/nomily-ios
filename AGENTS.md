# Nomily public repository guardrails

This repository is public. Treat every tracked file, commit message, generated
asset, and Git history operation as externally visible. If another instruction
conflicts with this file, stop and ask a maintainer before publishing.

## Never publish

- Internal chat excerpts, task numbers, codenames, staff or customer names,
  private domains, local paths, device serials, pairing data, support tickets,
  screenshots with personal data, recordings, transcripts, or diagnostics.
- API keys, passwords, cookies, tokens, certificates, provisioning profiles,
  private endpoints, QR credentials, authentication exports, or realistic
  secret-shaped data. Use `example.com`, `192.168.1.10`, and `YOUR_API_KEY`.
- Reverse-engineering notes, decrypted traffic, decompiled-client references,
  credential extraction tools, proprietary protocol specifications, or material
  based on a third party's non-public implementation.
- Third-party SDK binaries, headers, images, videos, fonts, or copied product
  copy unless redistribution rights, source, license, version, and intended use
  have been confirmed by a maintainer.

## Public product language

- Make only verified, current claims. A prototype, import path, screenshot, or
  unmerged branch is not evidence of public compatibility.
- Always write `Vobot V05E` in full. Do not claim direct pairing or connectivity
  with competitor devices without current written maintainer approval.
- Do not claim that Nomily is fully offline, fully self-hosted, or universally
  free. Approved pricing wording: Nomily does not charge a subscription fee;
  third-party ASR and LLM services may charge under their own terms.
- Explain that local ASR and Ollama are user-operated integrations; provider
  availability, retention, pricing, and data handling remain with that provider.

## Language and source rules

- Use English for source comments, default UI strings, README content, examples,
  CLI output, generated filenames, and configuration instructions.
- Keep translated README files, localization resources, language fixtures, and
  functional vocabulary data. Do not remove them merely because they are not
  English.
- Route visible UI text through localization. Do not add hard-coded Chinese text
  to Swift, Kotlin, JavaScript, Python, YAML, plist, or shell code.
- Keep source comments short, factual, and English. Do not store private design
  history or conversations in comments.

## Safe removal of SDKs and device features

1. Create a local rollback branch or tag and record its SHA.
2. Map all references with `git grep` or `rg`, including UI, configuration,
   scanning, transfer, tests, build files, and generated project files.
3. Remove the feature coherently. Never delete a framework or binary while
   imports, symbols, UI, documentation, or build links still reference it.
4. Regenerate Xcode project files where required and run the relevant build or
   test. Report a pre-existing baseline failure separately.
5. Remove public docs and assets that promise the removed feature.

If an integration shares core code with supported functionality, stop after the
dependency map and ask for a maintainer-approved refactor scope. Never push a
half-removed feature to `main`.

## Required pre-push checks

```sh
git diff --check
git grep -n -e '用户：' -e '饭耳' -e 'oazon' -e 'decompil' -e '逆向' -- . || true
git grep -nP '[\x{4e00}-\x{9fff}]' -- . ':!README.zh-*' ':!*.lproj/Localizable.strings' ':!**/values-zh*' ':!**/values-ja*' || true
```

Review every remaining match. It must be an approved translation, language
fixture, or functional vocabulary item. Then run the formatter, tests, build,
and asset validation relevant to the files changed.

## Git and publication safety

- Use focused commits. Stage files by name; do not commit build-number changes,
  IDE state, caches, or unrelated work.
- Never force-push, rewrite history, purge releases, delete tags, delete a
  repository, or change visibility without explicit current-task approval.
- Removing a file from `HEAD` does not erase its history. For a confirmed leak,
  stop publication and request approval for a separate history-rewrite and
  credential-rotation plan.
- Validate the ownership, license, language, personal-data exposure, and product
  claim of every new public image, video, or poster.

## Agent handoff

Before editing, state scope, assumptions, affected public claims, and a
verification plan. On completion, report the commit SHA, files changed, checks
run, known limitations, and anything intentionally not removed.
