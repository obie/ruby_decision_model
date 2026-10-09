---
created: 2026-10-07T18:33:29Z
branch: main
trigger: manual
restored: false
topic: v0-2-launch-announcement
---

# Handoff: 0.2.0 verified live, tagged, and drafted for an X article

## Goal
Get ruby_decision_model 0.2.0 checked against the real vendor APIs and announced on X Articles. The gem stays vendor-agnostic: every provider translates to and from System One. The 0.2.1 hardening from the previous handoff comes after the announcement.

## Current State
- **Release:**
  - 0.2.0 has been on RubyGems since 2026-10-07 04:03 UTC.
  - Annotated tag `v0.2.0` points at `5154d43`, the same commit as `main` and `origin/main`, and is pushed.
  - The GitHub Release is up at https://github.com/obie/ruby_decision_model/releases/tag/v0.2.0. Its notes are the CHANGELOG entry plus a "Tested live on 2026-10-07" section.
- **Live smoke tests, 2026-10-07: everything passed and no code changed.**
  - Native APIs: OpenAI `gpt-6-luna`, Perplexity `pplx-decider-v1.1-27b`, Cloudflare `clef` and `clef-flash`.
  - Through OpenRouter: Jev, Luna, Clef, Clef-flash, pplx-decider.
  - Calls took 0.35s to 1.4s.
- **Image test:** I made two fake screenshots, a 500 error page and an order confirmation. I asked OpenAI, Perplexity, Clef and Clef-flash "Does the attached screenshot show an error?"
  - The error page scored between 0.967 and 1.0.
  - The confirmation scored between 0 and 0.012.
- **`Response#id` is nil on OpenAI and Perplexity.** That's correct: their raw responses only carry `model`, `answers` and `usage`.
- **Not tested live:**
  - Databricks. The user doesn't use it, and `ai_decide` only runs inside a customer's own workspace.
  - Typesafe native. There's no `TYPESAFE_API_KEY` here, though Jev passed through OpenRouter.
  - System One servers.
- **X article draft:** a private artifact at https://claude.ai/artifact/FpeBg7Uv2rCxSaZbAhJySH.
  - The page has copy buttons for the title, the body and a ~250-character post to share it with. The body copy keeps headings, lists, bold and links.
  - The three code samples are syntax-colored PNG images. The copied body has `[Code image N]` placeholder lines where the user drags each image in.
  - The user hasn't posted it or sent feedback yet.
- **Article source:** it lives in this session's scratchpad at `/private/tmp/claude-501/-Users-obie-projects-ruby-decision-model/b4aa84c8-60f4-4224-9ea0-fcfae220d044/scratchpad/article/`.
  - `template.html` holds `{{codeN}}` placeholders, and a small Ruby step embeds `code1..3.png` as data URIs into `ruby-decision-model-0-2-article.html`.
  - `render.rb` turns `codeN.rb` into a colored SVG, and `magick -density 192` turns that into a PNG.
  - The scratchpad goes away with the session. A new session should read the artifact with `Artifact action: "read"` and build edits on what comes back.
- **Keys:** they live in `.env.smoke` at the repo root, which has mode 600 and is ignored by the new `.env*` line in `.gitignore`.
  - Variables: `OPENAI_API_KEY` (followed by a harmless `# comment` on the same line), `PERPLEXITY_API_KEY`, `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`.
  - The Cloudflare value is an account-owned `cfut_` token with Workers AI Read only, and that was enough for `/ai/run`.
  - Load them with `set -a && source .env.smoke && set +a`.

## Key Decisions
- **Never print or Read `.env.smoke`.** A PreCompact hook copies the transcript into Nexus. To change the file, use a script that prints only variable names and lengths.
- **The article's numbers all come from live runs.** That covers the five-model ticket comparison, the image scores and the `# => 0.91` in the code sample (gpt-6-luna's real answer). Re-run before changing any of them.
- **The code in the article is images.** X's article editor may not keep code formatting. Nobody has checked whether it supports code blocks.
- **The release notes and article say Databricks and System One have unit tests only.** The article asks readers with a Databricks workspace to run `rake smoke TARGETS=databricks`.
- **The article is written in first person as the user.** It says they don't use Databricks. Its title is "ruby_decision_model 0.2: OpenAI, Cloudflare, Perplexity and Databricks".
- **Pushing a tag triggers no workflow.** `release.yml` runs only on `version.rb` changes to `main` or a manual dispatch. Tagging can't republish the gem.

## Modified Files
- `.gitignore`: added `.env*`. Uncommitted.
- `docs/handoffs/`: untracked. It holds this file, `2026-10-06-decision-providers-hardening.md`, and `_archive/2026-10-07-main.md` (the compaction stub, already archived by the restore hook).
- `.env.smoke`: ignored, and must never be committed.

## Failed Approaches
- **ImageMagick `pango:` input** fails with "no decode delegate". `magick -list format` shows PANGO with `---`, meaning no read support. Render code as SVG `<text>`/`<tspan>` through librsvg instead.
- **Pasting Cloudflare's "test this token" curl snippet as the token value** puts the token on the next line after `Bearer`. It got pulled out with a regex on `Bearer\s+(\S+)`.

## Files to Read
- `docs/handoffs/2026-10-06-decision-providers-hardening.md`: the 0.2.1 hardening list, README debt, the `decide` follow-up, and the earlier design decisions. All of it is still current.
- `CHANGELOG.md`: the 0.2.0 entry.
- `Rakefile`: the `smoke` task. Use `TARGETS=provider[:model],...` and `SMOKE_IMAGE=path`.
- The artifact at https://claude.ai/artifact/FpeBg7Uv2rCxSaZbAhJySH, if the user wants article edits.

## Next Steps
1. Make any article edits the user asks for, after they post or review it. Republish to the same artifact URL, reading it first if this is a new session.
2. Ask whether to commit the `.gitignore` change, and whether `docs/handoffs/` should be committed or ignored.
3. Tag `v0.1.0` at `264fad7` and create its GitHub Release if the user wants it. I offered and they haven't answered.
4. Remind the user to rotate the OpenAI, Perplexity and Cloudflare keys and delete `.env.smoke` once testing is over. A screenshot in the chat showed the first ~40 characters of each key.
5. Fill the README gaps from the docs audit:
   - `Client#open_timeout`.
   - `timeout:` also sets the write timeout.
   - `configured?` in the provider hooks list.
   - Databricks `error_message` handling and the `https://` it adds to a bare host.
   - `Images` raising `ArgumentError`.
   - OpenAI raising `RequestError` when instructions are missing.
6. Work through the 0.2.1 hardening list in the 2026-10-06 handoff.
7. In the `decide` gem, pass `MissingAnswers#answers` and `#refused` through, and update its gemspec description, which still says "Typesafe Jev via OpenRouter".
8. Delete the merged remote branch `feat/new-decision-providers` if the user wants it gone.

## Open Questions
- Does the user want `v0.1.0` tagged and released?
- Should `docs/handoffs/` live in git or in `.gitignore`?
- Does X's article editor support code blocks? If it does, the image placeholders could become text.
- Carried over from the 2026-10-06 handoff, all still open:
  - Should `http://` base URLs with keys be rejected?
  - Should `ask` get a partial-refusal mode?
  - Should the OpenRouter timeout depend on the model?
  - Ollama's System One support is still unconfirmed.
