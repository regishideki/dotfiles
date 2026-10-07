# Reproducing a frontend render-time crash in a headless browser (no auth)

Goal: empirically prove a React render-time error (context hook outside its provider,
`foo!.id` on undefined, etc.) happens WITHOUT a fix and stops WITH it — in a real browser,
without Auth0 login, a live BFF, or real entity IDs.

The trick is to render the REAL component in a throwaway `repro/` folder inside the repo,
with a MINIMAL provider stack, and toggle the fix via `patch`/git to show crash → clean.

## Worked example (the `useRelatedObjectives` context leak)

Bug: `ObjectivesToggle` (calls `useRelatedObjectives()`, which throws when outside its
`RelatedObjectivesProvider`) was rendered by the SHARED `DirectAssessmentsViewLayout`, but the
provider only wrapped the `speech-therapy` route — so every `occupational-therapy` direct
assessment crashed. Fix: `{disciplineSegment === 'speech-therapy' && <ObjectivesToggle />}`.

Repro harness rendered `DirectAssessmentsViewLayout` on an OT pathname, with these providers
only (NO `RelatedObjectivesProvider`, to reproduce the prod condition).

## The three harness files

`repro/vite.config.ts` — alias resolution is the hard part. The repo resolves bare imports
(`contexts/...`, `pages/...`, `components/...`, `utils/...`, `types`) via `tsconfig.json`
`baseUrl: "./src"`, NOT an alias map. So point `vite-tsconfig-paths` at the repo root and let
Vite read `../src`:

```ts
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tsconfigPaths from 'vite-tsconfig-paths';
import path from 'node:path';

const repoRoot = path.resolve(__dirname, '..');

export default defineConfig({
  root: __dirname,
  plugins: [react(), tsconfigPaths({ root: repoRoot })],
  server: { port: 5174, open: false, fs: { allow: [repoRoot, __dirname] } },
});
```

`repro/index.html` — just `<div id="root">` + `<script type="module" src="./main.tsx">`.

`repro/main.tsx` — the minimal stack. Key: stub heavy providers by providing the EXPORTED
context directly; use the real provider when the context is module-private.

```tsx
import React from 'react';
import ReactDOM from 'react-dom/client';
import { MemoryRouter } from 'react-router-dom';
import { ToastContext } from '../src/contexts/toast';           // EXPORTED → stub directly
import { ModalProvider } from '../src/contexts/modal';           // context private → real provider
import { DirectAssessmentsProvider } from '../src/contexts/DirectAssessmentsProvider';
import { DirectAssessmentsViewLayout } from '../src/pages/DirectAssessments/components/DirectAssessmentsViewLayout';
import '../src/i18n';                                            // side-effect init for useTranslation

const noop = () => {};
const trigger = { success: noop, error: noop, warning: noop, info: noop, liam: noop };

class Boundary extends React.Component<{ children: React.ReactNode }, { error: Error | null }> {
  state = { error: null as Error | null };
  static getDerivedStateFromError(error: Error) { return { error }; }
  componentDidCatch(error: Error) { console.error('[REPRO-CRASH]', error.message); }
  render() {
    if (this.state.error)
      return <div data-testid="crash" style={{ fontFamily: 'monospace', color: 'red' }}>
        <pre>{this.state.error.message}</pre></div>;
    return this.props.children;
  }
}

const OT_PATH =
  '/panel/clinical-cases/case-id/assessments/direct-assessments/registry-id/occupational-therapy/arousal-and-activity-level';

const assessments = [
  { title: 'Nível de alerta e atividade', name: 'arousal_and_activity_level',
    status: 'started', pathname: OT_PATH },
];

ReactDOM.createRoot(document.getElementById('root') as HTMLElement).render(
  <React.StrictMode>
    <MemoryRouter initialEntries={[OT_PATH]}>
      <ToastContext.Provider value={{ trigger } as never}>
        <ModalProvider>
          <DirectAssessmentsProvider assessments={assessments} isSavingAssessment={false}
            mode="view" onSave={async () => {}}>
            <Boundary>
              <DirectAssessmentsViewLayout assessmentName="Nível de alerta e atividade"
                loading={false}><div>form</div></DirectAssessmentsViewLayout>
            </Boundary>
          </DirectAssessmentsProvider>
        </ModalProvider>
      </ToastContext.Provider>
    </MemoryRouter>
  </React.StrictMode>,
);
```

## The provider stack for `DirectAssessmentsViewLayout`

`MemoryRouter` → `ToastContext.Provider` (stub) → `ModalProvider` (real) →
`DirectAssessmentsProvider` (real; needs `assessments` + `isSavingAssessment` + `mode` +
`onSave`) → `Boundary` → layout. No `RelatedObjectivesProvider` — that omission IS the bug.

- `ToastContext` is exported from `contexts/toast` → stub `{ trigger }` directly, skipping the
  heavy `<Toast />` that `ToastProvider` renders.
- `ModalContext` is module-private in `contexts/modal` → use the real `ModalProvider` (it's
  lightweight: just `useState` + `Suspense`).
- `DirectAssessmentsProvider` self-provides `FormProvider` (react-hook-form) and needs only
  `useLocation` (Router), `useToast` (stubbed), `useWakeLock` (no-op in headless).

## Run + verify loop

```bash
cd <repo>
# background shell defaults to Node 16 — Vite 7 needs >=20:
export PATH="$HOME/.nvm/versions/node/v20.19.2/bin:$PATH"
npx vite --config repro/vite.config.ts     # background=true, watch for "ready in"
```

Then with the Hermes `browser_*` tools (no Playwright install needed):

1. `browser_navigate('http://localhost:5174/')` → snapshot shows either the crash div or the
   rendered layout.
2. `browser_console()` → look for the `[REPRO-CRASH]` line (without fix) or a clean log (with
   fix). Note: `browser_console` accumulates across reloads and `clear=true` only clears
   `console_messages`, not `js_errors` — the snapshot + `console_messages` are the trustable
   signal; ignore stale `js_errors` entries.
3. Toggle the fix: `patch` the one line back, reload, confirm crash; re-apply, reload, confirm
   clean render.
4. `rm -rf repro` before committing — the repo stays code-only.

## Why the ErrorBoundary matters

Production wraps the app in an ErrorBoundary (`src/index.tsx`), which is exactly why Datadog
reports this class of bug as `handling: handled` + `is_crash: false` (not a white screen). The
harness boundary reproduces that: the component throws, the boundary catches, you read the
message. Without a boundary, React unmounts the whole tree and you only see it in the console.
