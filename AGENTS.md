# Jaegun Service Agent Guide

## Durable Design Decisions

- The user explicitly retired the event-only Option 3 prototype and selected the production-service Option 1 on 2026-08-03. The exact reference is `design/reference-service-home.png`.
- The deployed product is a responsive, mobile-first private church community service under `apps/web/`. It is not presented inside a phone frame.
- Preserve Option 1's hierarchy: church identity and greeting, one official community update, role-aware approval entry, recent post, and five-item navigation (`홈`, `게시판`, `채팅`, `교회`, `내 정보`). Retreat content is a data-driven post/event, not the permanent product shell.
- Keep minister and executive management experiences distinct. Ministers center member approval and pastoral community operations; executives receive a separate operations home plus yearly meeting-minutes and accounting-ledger areas.
- Executive office assignments (`회장`, `부회장`, `총무`, `서기`, `회계`) are year-scoped metadata separate from the authorization-bearing `executive` app role. A person may hold multiple offices, and selected offices tailor dashboard actions without granting the base executive role.
- The platform administrator renews executive offices for the current or next service year through the audited assignment flow. Legacy executive applications without an explicit office selection must be rejected and resubmitted, never approved into an unscoped executive role.
- Enforce office-specific write capabilities in the backend as well as the UI: authorized executive offices manage minutes or ledger entries, while all active executives in the same church may read the annual records. Ministers and ordinary members do not receive executive-record access by default.
- Use the Jaegun denomination-inspired orange, leaf-green, sky-blue, and deep-forest palette with readable Korean type and at least 44px tap targets.
- Keep the generated product mark and church landscape as real raster assets under `apps/web/public/assets/`; do not replace them with CSS or inline SVG approximations.
- The spreadsheet source is used only to pre-create church organizations. Never import attendee names, ages, gender, phone numbers, or inferred roles.
- Authorization is enforced in the backend: the platform administrator approves ministers and executives; active ministers or executives approve members only within their own church. UI capability checks are supplementary, never the security boundary.
- Annual executive assignments, meeting minutes, and accounting use the backend-authoritative `Asia/Seoul` service year. Signed-in clients must consume the server clock and schedule from its rollover delay so current/next-year controls and database authorization switch on the same Korean midnight boundary even when a device clock is wrong.
- Governance is hierarchical: one general assembly (`총회`) contains presbyteries (`노회`), and each presbytery contains church organizations (`교회`). Executive office assignments are year-scoped at the exact hierarchy level and must not silently grant a role at parent or child scopes.
- Signup and first-run onboarding use a presbytery-first dependent church selector. The client stores only the selected church ID as a prefill preference; the presbytery is always derived from that church and neither value grants membership or authority.
- Every governance office at general-assembly, presbytery, and church scope—including the church `pastor` office—is an explicit year-scoped assignment. A minister role may still approve members under the membership policy, but it does not implicitly grant governance officer-management authority.
- The current-year president and authorized pastor at a governance scope may manage that scope's executive assignments. They may grant a bounded delegation for an explicit scope, capability, and expiry; delegation never creates a platform administrator, executive membership, or implicit authority outside that scope.
- Presbyteries and churches expose scoped rosters to authorized signed-in users. Roster access and private profile fields are enforced by backend RLS/RPCs; the UI must not infer broader visibility from a presbytery label alone.
- Each church has four fixed ministry departments—`adult` (장년부), `young_adult` (청년부), `teen` (청소년부), and `elementary` (초등부). Their annual offices (`회장`, `부회장`, `총무`, `서기`, `회계`) are department-scoped metadata only and never grant the authorization-bearing `executive` role, member approval, meeting-minutes, accounting, or governance authority.
- Department officers are selected only from active members of the exact church without inferring department, age, gender, or role from the seed spreadsheet or profile data. The platform administrator or the church's explicit current-year `pastor` governance assignee manages these records; an ordinary minister role alone is not sufficient.
- Launch consent is five separate, versioned required records: `privacy_policy`, `sensitive_information`, `overseas_transfer`, `terms_of_service`, and `community_guidelines`. The two 2026-08-27 consent documents remain immutable historical evidence; historical terms remain addressable but were never consent evidence.
- Consent rollout must recognize only the exact legacy two-document set or the exact current five-document set. Unknown, duplicate, missing, mismatched-version, mismatched-URL, or mismatched-hash documents fail closed. Signup acceptance is revalidated immediately before Auth submission and recorded atomically from the exact nested metadata contract.
- Current required consent is a backend authorization boundary, not only a UI redirect. Before re-consent, RLS, RPCs, Storage, roster/count results, push/event queues, and protected application data must return no protected community data. Only legal documents, consent recording, logout, account deletion, and deliberately minimal self-service state remain available.
- Profile visibility preferences are backend-enforced field boundaries. Other users receive avatar, biography, email, and church-title fields only through actor-bound redacting RPCs, and private avatar objects must apply the same preference at Storage authorization time; direct table grants must never provide an unmasked bypass.
- The service currently accepts only users who attest that they are at least 14 years old. Do not permit under-14 signup until a separate verifiable guardian-consent flow is implemented.
- Production Supabase data and client-invoked Edge Functions use the project's `us-east-1` region. Pin client Edge Function invocations to `FunctionRegion.UsEast1`; changing the processing region requires a new factual overseas-transfer review and, when material, a new consent version.
- Media remains in hardened direct-upload mode for launch. Keep scanner/transcoder grants, workers, and schedules dormant until their reconciliation, derivative cleanup, and lease-generation safeguards are implemented and separately approved.
- Static Vite direct signed-media delivery has a documented maximum 60-second bearer revocation SLA until an authenticated, Range-capable media delivery service exists. Avatar and community-media signed URLs use a 60-second TTL with a 45-second client cache; session and consent transitions clear client caches immediately, while protected video renewal must revalidate the active actor, session epoch, and consent gate.

## Production Service

- Channels are member-created collaboration spaces, not administrator-provisioned rooms. Any active, consent-current church member may create public (within that church) or invitation-only private channels. Channel ownership/management must never grant church, executive, department, or governance authority. Preserve direct messages; introduce channels first, then threads/mentions and shared tasks/calendar in later stages. Invitations require acceptance; revocation of church membership must revoke private-channel participation permanently until explicitly invited again.

- Build production UI, routing, authentication, organization onboarding, boards, direct chat, media uploads, church profiles, and management screens in `apps/web/`.
- Keep Supabase migrations, RLS policies, secure approval RPCs, and organization seed data in `supabase/`.
- The frontend may provide an explicitly labeled local demo data adapter for visual QA, but production authority must come from Supabase Auth, Postgres RLS/RPCs, Storage, and Realtime.
- Production builds must fail closed when the public Supabase URL or anon/publishable key is missing. Never expose local demo personas or mock management data on a deployed production domain.
- Never expose a Supabase service-role key or other administrator secret in Vite client code. Only `VITE_SUPABASE_URL` and the public anon/publishable key belong in client environment variables.
- Root Vercel configuration deploys `apps/web/dist`; the legacy mobile prototype remains available for historical/runtime tests but is not the production entry point.

## Legacy Prototype Instructions

In ChatGPT Work Mode, run `sites-preview start "$PWD"`, open `http://terminal.local:4173/` in the cloud browser, and verify the rendered app and its primary interactions. Keep that preview open and tell the user to inspect it in the cloud browser; do not present the local URL as a user-facing chat link. In Codex Desktop, run the local server yourself, open the preview in the in-app browser, and provide the clickable local URL. Do not deploy to Sites unless the user explicitly asks to share, publish, or deploy. Do not give the user server-start instructions when you can run it.

Before planning or implementing any mobile-app change, read this `AGENTS.md` in full. It is the source of truth for the template's runtime and component guidance.

Before making substantial visual changes, use the Product Design plugin's `get-context` skill when the visual source is unclear or no longer matches the current goal. When the user gives durable prototype-specific design feedback, preferences, or decisions, record them in `AGENTS.md`.

When implementing from a selected generated mock, treat that image as the source of truth for layout, component anatomy, density, spacing, color, typography, visible content, and hierarchy.

## Editing Boundary

- Build app-specific UI in `src/Prototype.tsx` and `src/prototype.css`.
- Treat `src/App.tsx`, `src/main.tsx`, `src/styles.css`, `src/mobile/`, `public/assets/iphone/`, `public/assets/android/`, `public/assets/status/`, `vite.config.ts`, `worker/index.js`, and `scripts/prepare-sites-build.mjs` as protected runtime files. Do not edit, replace, remove, or recreate them unless the user explicitly asks to change the mobile runtime itself. For an explicit runtime change, update the affected lock hashes only after verifying the new runtime behavior.
- Run `npm run check:runtime` before preview or handoff. If it fails, restore the protected runtime instead of weakening or bypassing the check.
- `npm run build` preserves the mobile runtime and prepares the static Cloudflare Worker output required by Sites. Before a Sites handoff, confirm `dist/client/index.html`, `dist/server/index.js`, `dist/.openai/hosting.json`, and source `.openai/hosting.json` exist, then run `npm run test:sites`. Do not replace this project with a Vinext starter.

## Runtime Contract

- Preserve the mobile device runtime unless the user's task explicitly asks otherwise. Do not replace it with a standalone page. Visual fidelity applies to app-owned content inside the device screen, not to template-owned device chrome.
- Keep `App` composed around `PhoneFrame` -> `KeyboardProvider`, with `StatusBar`, app content, `HomeIndicator`, and `KeyboardDock` mounted inside the phone frame. `StatusBar` and the iOS home indicator are overlaid device chrome. When the Android keyboard is closed, the app viewport reserves the protected navigation-bar region instead of painting behind it. When the Android keyboard is open, preserve the current full-screen keyboard layout: its asset includes the IME navigation strip and the separate black navigation bar is hidden. iOS screens continue to paint behind the home-indicator area and own their safe-area content padding.
- Preserve the `iPhone` / `Pixel 10` device picker and both calibrated device presets. The Pixel screen is `427 x 952`; its `32 x 32` camera circle and `public/assets/android/navigation-bar.svg` bottom navigation bar are protected device chrome, not app content.
- Preserve the device picker's intentionally lightweight Codex styling in the top-right corner: its trigger wrapper is borderless and transparent, its trigger sizes to content, and its right-aligned menu uses the compact 3px inset plus the specified hairline and elevation shadow layers. Keep the prototype root and default app screen white.
- Preserve `StatusBar` as live device chrome, including its platform-specific typography, source status-icon assets, and spacing. Pixel 10 uses Roboto, Android indicators, and 32px top, left, and right padding. iPhone uses its iOS indicators, system typography, and calibrated spacing. Do not hardcode screenshot times like `9:41` into the status bar, replace its real-time clock, or move status bar content into app markup unless the user explicitly asks for a fixed/mock device time.
- `PhoneFrame` owns the calibrated device frame, screen portal, device picker, camera cutout, and custom cursor. Keep device assets in `public/assets/iphone/` and `public/assets/android/`; if an asset fails to load, repair the asset path or restore the asset instead of removing the frame, keyboard, or image render.
- Use `MobileScroll` directly for simple single-screen prototypes. Use `FlowStack` for conventional multi-screen flows whose routes can own their fixed header and footer; when using it, define each route as a `FlowScreen`: `{ id, header?, headerHeight?, footer?, footerHeight?, render }`, and use `flow.push(screen)`, `flow.pop()`, and `flow.replace(screen)` from `FlowStack` render callbacks or `useFlow()` instead of introducing another router.
- Use `Carousel` for a carousel, horizontal rail, swipeable cards, image or media strip, horizontally scrollable cards, chip rail, or other horizontal collection.
- For a layered app shell—such as a persistent composer, independently presented sheet, pushed/peek sidebar, or app-wide transition—compose directly in `Prototype.tsx` rather than forcing it through `FlowStack`. Keep app-owned fixed chrome as sibling layers outside `MobileScroll`.
- When using `FlowScreen`, put route-owned fixed headers or footers in `FlowScreen.header` or `FlowScreen.footer`. Set `headerHeight` to the visible app-toolbar height; `FlowStack` adds the device's top safe-area/status-bar inset automatically. Do not include `StatusBar` or its height in the header. Set `footerHeight` to the full app-footer height. `FlowScreen.footer` is an overlay, not reserved layout space; screens using it must add their own bottom content padding such as `padding-bottom: calc(var(--flow-footer-height) + var(--mobile-safe-area-height) + 24px)` so final content can scroll above the footer while still painting behind it.
- Render only scrollable content inside `MobileScroll`; it is for content that should move with scroll and rubber-band overscroll. Keep app-owned headers, nav bars, tabs, composers, and overlays outside it. This keeps scroll physics, safe areas, keyboard insets, scrollbars, and drag click suppression active without letting content paint under fixed chrome.
- Buttons, links, cards, and images inside `MobileScroll` should still allow drag scrolling when the pointer moves beyond tap slop. Use `data-scroll-drag="ignore"` only for rare controls that must own the drag gesture themselves.
- Do not add `var(--keyboard-height)` to ordinary screen/content padding inside `MobileScroll`; the scroll viewport already shrinks above the simulated keyboard. For custom fixed composers, search bars, or toast chrome, use `useKeyboardInsets().bottomInset`. It is relative to the app viewport: Android returns `0` while the closed-keyboard viewport already reserves navigation, then returns the keyboard height while open; iOS continues to clear the home indicator while closed and ride directly above the keyboard while open. Do not pin custom bottom chrome to `bottom: 0` or only `keyboardHeight`.
- Use `KeyboardInput`, `KeyboardTextarea`, or `MobileTextField` for every text-entry control. A raw `input` or `textarea` disconnects focus, keyboard animation, safe-area insets, and attached surfaces.
- Use `BottomSheet` for phone-scoped sheets. Its props are `open`, `onOpenChange`, `title`, optional `description`, optional `snap`, and `children`; it renders through the phone screen portal and dismisses the keyboard before opening.

## Horizontal Carousels

- Use `Carousel` for horizontally draggable cards, images, media, chips, or other horizontal collections. Do not recreate these with `overflow-x`, custom pointer handlers, or a generic div.
- `Carousel` can be nested directly inside `MobileScroll`. It owns horizontal gestures and automatically yields vertical gestures to the parent.
- Never put `data-scroll-drag="ignore"` on or around a `Carousel`; doing so prevents vertical parent scrolling when a gesture begins inside it.
- Do not add CSS scroll snapping to `Carousel`; its runtime owns momentum and release motion.
- Use `data-scroll-drag="ignore"` only when a control must prevent parent scrolling in every drag direction.

See `src/mobile/COMPONENTS.md` for the full component and gesture contract.

## Keyboard Rule

The simulated keyboard is a separate top-layer component. Before presenting anything that behaves like iOS navigation or modal UI, dismiss it first.

Call `keyboard.hide()` before:

- pushing, popping, or replacing FlowStack routes
- opening bottom sheets, action sheets, dialogs, menus, or navigation sheets
- starting transitions where the destination should not inherit text-input focus

`FlowStack` already hides the keyboard for `push`, `pop`, and `replace`. `BottomSheet` already hides it before opening. If you add new modal/sheet/navigation primitives, follow the same rule.

When a composer, search surface, or other keyboard-attached component closes, call `keyboard.hide()` in the same event before changing that component's open state. Position attached surfaces from `useKeyboardInsets()` rather than a separate timer or visibility flag so both dismiss together.

When any text-entry control loses focus, dismiss the simulated keyboard. If the control is custom or does not use the runtime's keyboard-aware fields, handle its blur event and call `keyboard.hide()` explicitly. Keep the keyboard open only when focus is moving directly to another text-entry control that should share the same keyboard session.

## Interaction Rules

- Do not trigger buttons or inputs after a pointer has become a drag. Preserve the drag suppression behavior in `MobileScroll`.
- Do not allow native browser image/file dragging inside the phone frame. Preserve the phone-level `dragstart` suppression and non-draggable image styles so scroll drags that begin on images still scroll the prototype.
- Use `KeyboardInput`, `KeyboardTextarea`, or `MobileTextField` for text entry so the simulated keyboard and safe-area insets stay connected.
- Fixed phone chrome should not animate with pushed screens. Screen content can animate; the status bar, camera cutout, and preview chrome should stay put.
- Keep the keyboard below the home indicator/safe area layer in z-index, and above ordinary app UI while visible.
- Keep the home indicator as the topmost safe-area layer in the z-index above everything else in the prototype.
