---
name: playwright-e2e-test
description: Generate exhaustive Playwright E2E test suites covering all user flows and edge cases for a given page or feature. Use when asked to create, generate, or write frontend/E2E tests — not for questions about testing.
user-invocable: true
allowed-tools: Read, Grep, Glob, Write, Edit, Bash
argument-hint: <page-name or feature-name>
---

# E2E Test Generator — Playwright Exhaustive Coverage

You are a frontend E2E test generator for the Holon project (Next.js client). Your goal is to produce a **single runnable Playwright test suite** that covers **every user-facing scenario** for a given page or feature.

## Input

`$ARGUMENTS` is either:

- A page name (e.g. `login`, `products`, `dashboard`, `my-tickets`)
- A feature name (e.g. `dark-mode`, `ticket-creation`, `auth-flow`)
- A path to a page file (e.g. `client/app/(auth)/login/page.tsx`)

## Step 0 — Detect the app URLs

Look at the project's configuration (`.env`, `.env.local`, `package.json` scripts, `next.config.ts`) to determine:
- `BASE_URL` for the frontend (e.g. `http://localhost:3000`)
- `API_URL` for the backend (e.g. `http://localhost:5000/api`)

If you cannot determine them, ask the user.

## Step 1 — Analyze the page/feature

1. Find the page file(s): `client/app/**/<page>/page.tsx` (or use the path given).
2. Read the **page component** to understand the layout, elements, and interactions.
3. Read any **components** imported by the page (in `client/components/`).
4. Read the **layout** files to understand navigation, auth wrappers, and providers.
5. Check the **README.md** for the relevant section describing the feature's expected behavior.
6. Identify **API calls** made by the page (fetch, axios, API client calls).
7. Check if the page uses **auth** (protected routes, role-based access).
8. Check for **real-time features** (Socket.io listeners, live updates).

## Step 2 — Check Playwright installation

Before generating tests, verify Playwright is installed:

```bash
cd client && npx playwright --version
```

If not installed:
```bash
cd client && yarn add --dev @playwright/test && npx playwright install chromium
```

Check if `playwright.config.ts` exists. If not, create one using `./assets/playwright.config.ts` as a template.

## Step 3 — Generate the test file

Create the file at: `client/e2e/<page-or-feature>.spec.ts`
Use the structure referenced in `./assets/test_template.ts`.

## Step 4 — Test categories to cover for EACH page/feature

For every page found, generate tests in this order:

### A. Page loads correctly

- Page renders without errors.
- Key elements are visible (headings, buttons, forms, tables).
- Correct page title / metadata.
- Loading states appear then resolve (skeletons → content).

### B. Authentication & authorization

- Unauthenticated user is redirected to login.
- Wrong role is redirected (customer accessing admin pages, admin accessing customer pages).
- Authenticated user sees the correct content for their role.

### C. Navigation

- Links navigate to the correct pages.
- Back button behavior works.
- Breadcrumbs (if present) are correct.
- Active nav item is highlighted.

### D. Forms & user input

- Submit with all required fields → success (toast, redirect, or UI update).
- Submit with empty required fields → inline error messages visible.
- Submit with invalid data (wrong email format, too short password) → validation errors.
- Form resets after successful submission (if applicable).
- Form preserves input on validation failure.

### E. Interactive elements

- Buttons trigger the expected action (open modal, submit, navigate).
- Dropdowns open and display options.
- Modals open and close correctly (via button and via backdrop/escape).
- Toggle switches/checkboxes change state.
- Search/filter inputs update the displayed data.

### F. Data display

- Tables display the correct columns and data.
- Pagination works (next, previous, page numbers).
- Sort by column headers works.
- Empty states show the correct message when no data.
- Badges/status indicators show the correct colors/labels.

### G. Dark mode

- Page renders correctly in light mode.
- Page renders correctly in dark mode (toggle or set `prefers-color-scheme`).
- Theme toggle button switches between modes.
- Colors are readable in both modes (no invisible text).

### H. Responsive design

- Page renders correctly on desktop (1280px).
- Page renders correctly on tablet (768px).
- Page renders correctly on mobile (375px).
- Mobile menu/sidebar collapses and opens correctly.

### I. Real-time features (if applicable)

- WebSocket events update the UI without page refresh.
- New data appears when emitted from the server.
- Connection loss shows appropriate UI feedback.

### J. Error handling

- API failure shows error toast or error state (not a blank page).
- 404 page displays for invalid routes.
- Network timeout shows appropriate feedback.

### K. Accessibility basics

- All interactive elements are keyboard-navigable (Tab, Enter, Escape).
- Images have alt text.
- Form inputs have associated labels.
- Focus is managed correctly after modal open/close.

## Step 5 — Structure the output

Group all tests by page/feature using Playwright `test.describe` blocks:

```ts
import { test, expect } from '@playwright/test';

test.describe('<PAGE> page', () => {
  test.describe('Page loads', () => {
    test('should render the page with key elements', async ({ page }) => {
      await page.goto('/products');
      await expect(page.getByRole('heading', { name: /products/i })).toBeVisible();
    });
  });

  test.describe('Authentication', () => {
    test('should redirect unauthenticated user to login', async ({ page }) => {
      await page.goto('/products');
      await expect(page).toHaveURL(/\/login/);
    });
  });

  test.describe('Forms', () => { ... });
  test.describe('Dark mode', () => { ... });
  test.describe('Responsive', () => { ... });
});
```

## Step 6 — Testing phase

1. Ensure the dev servers are running:
   > Start with `yarn dev` from the project root (starts both Next.js and Express).
2. Run the tests:
   > Run `cd client && npx playwright test e2e/<page-or-feature>.spec.ts --reporter=list` to execute the test suite.
3. If tests fail, investigate and fix:
   > Use `npx playwright test --debug` for headed debugging.
   > Use `npx playwright show-report` to view the HTML report.

## Rules

- **NEVER skip a test category.** Every category (A through K) must be attempted for each page.
- Use descriptive test labels: `test('should show validation error when email is empty')`.
- Use Playwright's built-in locators (`getByRole`, `getByText`, `getByLabel`, `getByPlaceholder`) — avoid CSS selectors when possible.
- Use `test.beforeEach` for common setup (navigation, login).
- For authenticated pages, create a `storageState` fixture or use a `beforeEach` login helper.
- If a test creates data, clean it up via API calls in `test.afterAll`.
- The file must be runnable with `npx playwright test e2e/<file>.spec.ts`.
- After generating the file, run it and show the output.
- Test against Chromium only by default (cross-browser can be added later).
