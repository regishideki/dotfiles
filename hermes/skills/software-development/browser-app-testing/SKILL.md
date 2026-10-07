---
name: browser-app-testing
description: Use when testing a web app in a browser (isolation, auth).
version: 1.0.0
metadata:
  hermes:
    tags: [browser, testing, e2e, playwright, computer-use, auth]
    category: software-development
---

# Browser app testing

When the user needs to *test a web app in a browser* (not just read the
code), the single most important decision is **isolation**: do we drive
the user's real browser, or spin up our own? Getting this wrong is the
#1 reason "accessing the browser" goes badly.

## The core insight: two different kinds of "background"

"Drive in the background" means two different things, and they get
confused:

1. **OS-level background** — what `computer_use` (cua-driver) does. The
   agent's cursor never moves, keyboard focus is not stolen, Spaces are
   not switched. This is real and works.
2. **App-state isolation** — NOT what `computer_use` gives you. The
   browser's *active tab* and *focused field* are **shared mutable
   state**. If the user switches tabs or clicks while you drive their
   Chrome, your next action (type a URL, click) lands on *their* tab,
   not yours. You interfere at the app-state level even though the
   cursor is isolated.

Consequence: **driving the user's real browser can never be fully
isolated from them.** True isolation requires a **separate browser
instance with its own profile**. That is what "Claude opening a
separate session" almost always meant in practice.

## Three options, ranked for parallel work

1. **Playwright with its own browser + profile** — full isolation. The
   user can work in their Chrome and you test in parallel with zero
   interference. Best for repeatable/E2E (screenshots, assertions, CI)
   AND for parallel exploratory work.
2. **Chrome with `--user-data-dir` (separate profile), driven by
   `computer_use`** — isolated tabs/state, still a real visible browser
   the user can open on another Space to watch. Middle ground.
3. **`computer_use` on the user's real Chrome** — best ONLY for "look
   at MY screen and help me" (the user drives, you observe/assist). Bad
   for parallel isolated work because of shared app state.

## The auth wall (authenticated PWAs)

Most real apps (GenialCare clinical-panel, etc.) require Auth0/SSO +
a GraphQL BFF. Any *fresh* browser — headless Playwright or a new tab —
hits the login screen and appears "broken". That is an environment
problem, not a tool problem. Solve it by either:

- reusing an **already-authenticated session** (drive the user's
  logged-in Chrome), or
- Playwright **`storageState`**: log in once, save cookies/token to a
  JSON file, then `browser.newContext({ storageState })` to reuse.

Check the app's auth shape first: look for `Auth0Provider`, `VITE_*`
env keys (`VITE_AUTH0_*`, `VITE_BFF_API_URL`), and `import.meta.env`
in the code — that tells you the login + backend the browser must reach.

> **Auth0 PKCE means drive the panel's OWN login, not a hand-built auth0.com
> URL.** The panel uses `loginWithRedirect` with PKCE (`code_verifier` stored in
> `localStorage`, `code_challenge` in the URL). If you bypass it — e.g. navigate
> a remote `browser_*` (Browserbase) session straight to the auth0.com
> `/authorize` URL and fill the form — Auth0 redirects back, but the panel's
> code exchange fails (no `code_verifier`) and you land unauthenticated on the
> Welcome screen. For any *authenticated* capture, use local Playwright
> (`capture.mjs`) which clicks the panel's real "Entrar" button, preserving
> PKCE end-to-end.

## computer_use pitfalls on macOS Chrome

Concrete, durable behaviors observed:

- **Keyboard menu-equivalents don't land in background.** `key` with
  `cmd+t`, `cmd+l`, etc. returns `effect: "unverifiable"` with
  `escalation.recommended: "foreground"`. Do NOT silently retry; climb
  the ladder or use a different route.
- **Pixel/element CLICKS DO land in background.** Clicking the "New
  Tab" button (by coordinate or element index) opened a tab while
  `cmd+t` did not. Prefer clicks over hotkeys for background driving.
- After a click, **re-capture and verify** — `effect: "unverifiable"`
  means "delivered, confirm yourself", not "failed".

## Driving the isolated Chrome in the background (hard-won details)

These are the traps that burn the most time when driving a separate Chrome
profile while the user keeps working in their own apps:

- **Coordinate spaces differ between surfaces.** `cua-driver call
  get_window_state` (and the raw `click`/`hotkey`/`type_text` tools) report
  `frame.x/y` in **SCREEN** coordinates, but `computer_use`'s
  `coordinate=[x,y]` is **window-local** (0,0 = the target window's top-left).
  To click something found via `get_window_state`, subtract the AXWindow
  element's `frame.x/y` origin first. When in doubt, have the raw cua-driver
  `click` write a `debug_image_out` crosshair PNG to confirm the space before
  trusting a pixel click.
- **`screencapture -R` captures the FOREGROUND screen, not your window.** If
  the user's own app covers your isolated window, you grab the wrong pixels.
  To save a *background* window's screenshot, use
  `cua-driver call get_window_state '{"pid":..,"window_id":..,"screenshot_out_file":"/tmp/x.png"}'`
  — it captures via AX/window targeting, not the screen.
- **JS-rendered pages stay blank in an occluded/background tab** (Chrome
  throttles rendering for hidden tabs). Auth0 Universal Login and similar SPA
  forms render empty until you front the window:
  `cua-driver call bring_to_front '{"pid":..}'` forces the render, then
  re-`get_window_state` to read the now-populated form.
- **Typing into a browser TAB is the fragile rung.** For Chromium page content
  the AX `type_text` write is refused (driver won't trust the echo). Prefer
  `type_text`'s **px form** (pass `x,y` to pixel-click-focus + type in one
  call) or the `page` tool (CDP). Secure/password `<input>` fields are the
  worst — keystrokes get dropped/truncated. To enable CDP mutation (`page`
  `execute_javascript`/`insert_text`/`type_keystrokes`), set
  `CUA_DRIVER_ENABLE_LEGACY_PAGE_MUTATIONS=1` and restart the daemon.
- **Focus competition with the user truncates typing.** Background navigation
  and reading (AX) don't steal focus, but *typing* is focus-sensitive: every
  click the user makes elsewhere steals focus mid-keystroke and the input lands
  partial (e.g. 3 chars of a 21-char password). Fix: `delivery_mode:"foreground"`
  on the type, or ask the user for a ~10s pause. This is the one place the
  background co-work model genuinely breaks down.
- **Navigate the isolated Chrome via `open`, not the address bar.** The `return`
  key in a background address bar often won't commit. Route by profile instead:
  `open -na "Google Chrome" --args --user-data-dir=~/.chrome-agent-profile "http://localhost:5050/"`
  (Chrome's single-instance-per-profile forwards to the running isolated
  instance).
- **`hotkey` takes `keys` as an ARRAY** (`["cmd","v"]`, not `"cmd+v"`) and
  accepts `x,y` to pixel-click-focus before firing the combo — useful for
  paste-into-a-field.
- **Custom components without an AX role can't be clicked by element index.**
  Design-system wrappers (e.g. antd `Card` with `onClick`) expose only their
  inner text/image in the AX tree — an `element_index` click returns `element
  does not advertise AXPress` (a no-op). Only a pixel click hits them, and that
  fails when the window is occluded. When you hit this, either navigate by URL
  instead, or click a *native* `<button>`/`<a>`/`<input>` sibling. This bit hard
  on the clinical-panel Welcome screen (tenant cards are antd `Card`s).

## Verification steps

- Confirm a new tab/page actually opened (check window title / AX tree),
  don't trust the returned `verified` flag alone.
- When co-working, ask the user whether their cursor moved — that's the
  acceptance test for OS-level background.
- If the user reports interference, it's app-state (shared tab/focus),
  not cursor — escalate to a separate browser instance, not "retry".

## Embedding screenshots into a PR body

When the point of the capture is a before/after fix, the user often wants the
images IN the PR description. `gh pr create --body` only accepts markdown with
image URLs — it cannot upload files. Host the PNGs, then reference them:

> **Do NOT commit the screenshot PNGs to the feature branch** (e.g. a
> `docs/screenshots/` folder). The user rejected this explicitly — it pollutes
> the repo with binary artifacts and forces a `reset` + force-push to undo.
> Host the PNGs and reference the URL in the description; the branch stays
> code-only.

- **`gh gist create` rejects binary files** — fails with `binary file not
  supported`. Don't waste a round-trip on it.
- **`0x0.st` is currently disabled** (returns "uploads disabled because it's
  been almost nothing but AI botnet spam"). Don't rely on it.
- **`catbox.moe` works, anonymous, no auth:**
  ```bash
  curl -s -F "reqtype=fileupload" -F "fileToUpload=@shot.png" https://catbox.moe/user/api.php
  # → https://files.catbox.moe/xxxx.png
  ```
- Build the body in a file and pass `--body-file` to avoid quoting hell:
  ```bash
  cat > /tmp/pr-body.md << 'EOF'
  ## Antes
  ![antes](https://files.catbox.moe/xxxx.png)
  ## Depois
  ![depois](https://files.catbox.moe/yyyy.png)
  EOF
  gh pr create --draft --base main --head "$BRANCH" --title "..." --body-file /tmp/pr-body.md
  ```

## GenialCare specifics

clinical-panel (React/Vite PWA) uses Auth0 (org Genial / Mindplace) +
GraphQL BFF (`VITE_BFF_API_URL`). `yarn start` runs vite dev. There is
no local backend in this repo — the dev BFF points at a remote
environment. See `genialcare-local-dev` for env/ports/CORS.

- **Port 5050** is set in `vite.config.ts`. A sibling `clinical-panel` repo's
  dev server often holds 5050 — if `yarn start` falls back to 5173, free the
  port (`lsof -nP -iTCP:5050 -sTCP:LISTEN` → kill the sibling's `yarn start`).
- **Node:** `.nvmrc` pins `v20.19.2` but the shell default is 16.14.0, which
  crashes Vite 7. Prefix `yarn start` with
  `export PATH="$HOME/.nvm/versions/node/v20.19.2/bin:$PATH"`.
- **Welcome screen is a 2-step login:** the tenant cards are antd `Card`s
  (no AX role — see the custom-component pitfall) that only `setTenant`; a
  hidden-until-selected "Entrar" button then calls `loginWithRedirect`. So
  select a card, THEN press "Entrar". Dev credential lives in memory
  (`dev@genialcare.com.br`, email == password); Auth0 tenant is
  `dev-cv1yf3pz.us.auth0.com`.
- **ID-free routes for quick screenshots:** `/panel/home`, `/panel/settings`,
  `/panel/users/pendencies`, `/panel/users/tasks`, `/panel/users/sessions`.
- **Getting a `:clinicalCaseId` to reach deep routes:** after login, land on
  `/panel/home` and WAIT for data first — the home fires `GET_HOME_PAGE_DATA`
  and renders "Carregando..." until it resolves. The clinical-case cards are
  `<Link>`s (`ClinicalCaseCard` → `buildURL.toClinicalCase(id)` =
  `/panel/clinical-cases/<id>/overview`), NOT `data-testid` selectors, so
  extract them by href (a half-loaded home yields `[]` links):
  ```js
  const spinner = page.locator('text=Carregando').first();
  await spinner.waitFor({ state: 'visible', timeout: 5000 });
  await spinner.waitFor({ state: 'hidden', timeout: 30000 });
  const hrefs = await page.$$eval('a[href*="/panel/clinical-cases/"]',
    els => [...new Set(els.map(e => e.getAttribute('href')))]);
  // then regex /\/panel\/clinical-cases\/([^/]+)/ to pull the UUID
  ```
  Then navigate direct: `/panel/clinical-cases/<id>/assessments/direct-assessments`
  (or whatever sub-route). This beats guessing an ID or scraping a
  still-loading home.
