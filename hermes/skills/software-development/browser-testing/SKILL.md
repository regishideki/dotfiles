---
name: browser-testing
description: Use when you need to test a web app in a browser.
---

# Browser Testing — choosing the mode & driving it reliably

When the user asks you to "open the app in a browser and test it", the #1
mistake is reaching for the wrong tool and then getting stuck. Two facts
drive everything:

1. **Background driving is NOT isolation.** `computer_use` (cua-driver) never
   moves the user's cursor or steals OS focus, but the *browser* (tabs, focused
   field, scroll) is shared mutable state. If the user touches the same window
   mid-action, you clobber each other.
2. **Key-combo verdicts lie.** `computer_use` frequently reports `effect:
   "unverifiable"` (and suggests escalating to foreground) for `return`,
   `cmd+t`, etc. — but the key actually landed. ALWAYS verify by re-capturing
   before believing a "didn't land" verdict.

## DEFAULT: Playwright headless

For the #1 goal — "navigate the panel and capture N screenshots" — reach for
**Playwright headless**, not `computer_use`. It renders the page fully (JS
included), fills forms via CDP (`page.fill` — no focus, no CGEvent truncation),
and captures PNGs with zero focus competition with the user's work. You lose
live visibility only. Use `computer_use` (isolated/foreground Chrome) only when
you need to WATCH the screen live or click something that has no stable
selector.

Ready-to-run script: `scripts/capture.mjs` (login flow + 10 routes). Setup:

```bash
mkdir -p ~/clinical-panel-playwright && cd ~/clinical-panel-playwright
# node >= 20 (Vite 7 needs it); install chromium once
npm init -y && npm i playwright && npx playwright install chromium
node capture.mjs
```

Key selectors that WORK (verified against the real app):
- Welcome clinic card: `[data-testid="tenant-option-genial_care"]`
- Welcome login button: `button:has-text("Entrar")`
- Auth0 email: `input[type="email"], input#username`
- Auth0 submit (email→password): `button[type="submit"]`
- Auth0 password: `input[type="password"], input#password`
- Back to panel: `waitForURL(/panel\/home/)`
- Wait for data: `locator('text=Carregando').first()` — wait visible→hidden.
  A fixed `waitForTimeout` is too short; GraphQL data loads after the spinner
  clears (you'd screenshot a "Carregando..." blank).

## Choosing the mode

| Mode | You watch live? | Can user interfere? | Use when |
|---|---|---|---|
| `computer_use` on the user's real Chrome | yes | yes, and it risks their tabs | quick "look at my screen and help" / user is too lazy to re-login |
| `computer_use` + isolated Chrome profile | yes | yes, but throwaway | testing while watching; low risk (relaunch fixes anything) |
| Playwright **headed** | yes | a little | scripted/step-by-step via API, visible window |
| Playwright **headless** | no (screenshots only) | no | CI, repeatable E2E, zero interference |

Playwright ALWAYS drives its own bundled Chromium (own profile), never the
user's Chrome — headed = window visible, headless = invisible. Control is via
CDP (direct to the page), not mouse/keyboard simulation, so no cursor and no
tab-focus races.

## Isolated Chrome recipe (middle ground, the usual answer)

Launch a separate Chrome profile so it's fully isolated from the user's tabs,
then drive THAT instance by pid/window_id (never by `app="Google Chrome"`
alone, which is ambiguous when two instances run).

```bash
mkdir -p ~/.chrome-agent-profile
open -na "Google Chrome" --args \
  --user-data-dir=/Users/$USER/.chrome-agent-profile \
  --no-first-run --new-window "https://example.com"
```

Then:
1. `computer_use(action="list_windows")` → find the new instance's `pid` and
   `window_id` (distinguish by window title; the user's Chrome keeps its own
   title, e.g. a GitHub PR).
2. Every capture/click/type/key after that passes BOTH `pid=` and `window_id=`
   so you never touch the user's Chrome.

The isolated profile is throwaway: if the user grabs the window and breaks your
state, just close it and relaunch fresh — no important tabs are at risk.

## Driving loop (verified against real use)

1. `capture` (mode=`som` or `ax`) to get element indices.
2. Click by `element=N` (much more reliable than coordinates).
3. Type via `type` — usually returns `effect: "confirmed"`.
4. `key` combos (`return`, `cmd+t`) often return `unverifiable` — **re-capture
   and check the window title / DOM state instead of trusting the verdict**.
   The action usually landed.
5. Re-capture after every state-changing action to confirm.

## Pitfalls

- **Auth wall.** The GenialCare clinical panel is Auth0 (org Genial/Mindplace)
  + GraphQL BFF (`VITE_BFF_API_URL`). A fresh browser/isolated profile lands on
  the Auth0 login. Reusing an already-logged-in session (the user's real
  Chrome) skips this; a fresh profile or Playwright must log in again or reuse
  a saved `storageState`.
- **Don't escalate to foreground on "unverifiable".** That verdict is almost
  always a false negative for keys/combos. Only escalate after you've
  re-captured and confirmed the action truly did nothing.
- **`cmd+t` / menu key-equivalents** sometimes genuinely need the window
  fronted; prefer clicking a real button (e.g. Chrome's "New Tab" button) over
  the shortcut when driving in background.
- **Multiple Chrome instances** break `app=` targeting — always pin pid +
  window_id.
- **cua-driver sessions expire on idle and do NOT self-heal mid-session.** If
  `computer_use` returns `session '...' has ended` while `list_apps` (stateless)
  still works, the session binding is stale. **Recover WITHOUT `/new`** by
  reviving the session directly:
  `cua-driver call start_session '{"session":"<id>","capture_scope":"auto"}'`
  (the `<id>` is in the error message, e.g. `hermes-1039d7881326`). It returns
  `"revived": true` and capture/list_windows work again immediately. Re-calling
  with the same id is idempotent (refreshes idle-TTL). Killing cua-driver
  processes mid-session makes the break permanent — don't `kill` the daemon
  (pid from `cua-driver status`); use `start_session` above, or `/new` as a
  last resort.
- **Saving a screenshot FILE needs `screencapture`, not `computer_use`.** When
  the main model is text-only (e.g. deepseek-v4-pro), `computer_use` capture
  returns only a *text description* of the image (routed to the auxiliary
  vision model), not bytes. Use macOS `screencapture -x` (full screen) or
  `screencapture -R x,y,w,h` (region — current screen only, does NOT reach
  windows on other Spaces). `-R` takes POINT coordinates, so the `bounds`
  from cua-driver's AX window element (`[x, y, w, h]`) map 1:1 to `-R` args;
  the output PNG is Retina 2x (a 1151×642 pt window → 2302×1284 px). For an
  off-screen window you need cua-driver's window targeting.

## Co-work (background) limits & focus

When the user is actively working in other apps, the isolated window is
occluded/backgrounded. Which operations stay non-disruptive:

| Operation | Steals focus? | Notes |
|---|---|---|
| Read window state (AX tree) | No | always safe |
| Click button/link by `element_index` (AX) | No | works on background/hidden windows |
| Click by pixel (x,y) | N/A | hits whatever is on-screen at that point — wrong target if occluded |
| Navigate via `open -na "Google Chrome" --args --user-data-dir=... URL` | **Yes** | reliable nav, but `open` activates Chrome |
| Navigate via CDP `browser_navigate` | No | needs `browser_prepare` (approval) |
| Type text | **Yes** | focus-sensitive; user's clicks steal focus mid-typing |

Findings from real co-work testing:

- **`open` navigation is the pragmatic reliable path** but steals focus every
  time (activates Chrome). Use it when the user isn't mid-typing elsewhere;
  warn them first.
- **JS-rendered pages don't render in a background tab** (Chrome throttles
  background-tab rendering). The Auth0 Universal Login form stayed blank until
  `bring_to_front`. `open`-navigated routes DID render (open briefly activates
  Chrome). To render a blank background page: `cua-driver call bring_to_front
  '{"pid":N}'`, wait ~2s, re-capture.
- **Secure password fields reject CGEvent typing** — even `delivery_mode:
  "foreground"` delivered 0 chars, and paste/type got truncated (~4 chars).
  Reliable: have the user type the credential, or CDP `browser_type`. Don't
  burn time re-trying CGEvent on `type=password`.
- **Icon-only side menus (no aria-label) don't expose AX targets.** The panel's
  left menu is icon-only, so element-clicking it is impossible; navigate by URL
  (`open`) or pixel-click (fragile when occluded). Custom components without an
  accessible role (antd `Card` with `onClick`) have the same problem.
- **Screenshot a background window** with `cua-driver call get_window_state
  '{"pid":N,"window_id":M,"screenshot_out_file":"/tmp/x.png",
  "include_screenshot":true}'` — `screencapture -R` grabs the SCREEN (the
  user's foreground app), not the occluded window.

## clinical-panel specifics

- Dev server: `yarn start` (Vite). There is also a sibling `clinical-panel`
  repo; make sure you're starting the right one.
- Backend is remote (BFF), not local — the panel needs `VITE_BFF_API_URL`
  reachable plus Auth0 login to do anything past the login screen.
- Env files (.env.development / .env.staging / .env.production) are
  secret-bearing — don't read them directly; use `grep -oE '^[A-Z_]+'` to see
  key names only if you must.
- Auth0 dev tenant: `dev-cv1yf3pz.us.auth0.com` (app "Panel App"). Login is a
  2-step flow: pick a clinic (Genial Care / Mindplace Kids) then "Entrar" →
  Auth0 Universal Login (email step → password step). Dev login:
  `dev@genialcare.com.br` (email = password).
- Top-level routes (no ID needed): `/panel/home`, `/panel/settings`,
  `/panel/users/pendencies`, `/panel/users/tasks`, `/panel/users/sessions`,
  `/panel/users/marketplace`. Most other routes need a `:clinicalCaseId`.
  See `src/routes/Routes.tsx` for the full map.
