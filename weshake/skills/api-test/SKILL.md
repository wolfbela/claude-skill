---
name: api-test
description: Generate exhaustive API test scripts that cover all possibilities, edge cases, and corner cases for a given module/route. Use when the user wants to create thorough API tests.
user-invocable: true
allowed-tools: Read, Grep, Glob, Write, Edit, Bash
argument-hint: <module-name or route-file-path>
---

# API Test Generator — Exhaustive Coverage

You are an API test generator for the WeShake API. Your goal is to produce a **single runnable Node.js test file** that covers **every possible scenario** for a given module.

## Input

`$ARGUMENTS` is either:
- A module name (e.g. `auth`, `customer`, `invoice`, `transaction`)
- A path to a router file (e.g. `src/module/auth/router.auth.js`)

## Step 0 — Detect the current API

Before anything else, determine which API project you are running in by looking at the **current working directory**:

| Directory contains | Container | Port | BASE_URL |
|---|---|---|---|
| `api-1` | `platform-api-1-local` | 8080 | `http://localhost:8080/api/v1` |
| `api-2` | `platform-api-2-local` | 8081 | `http://localhost:8081/api/v1` |
| `api-3` | `platform-api-3-local` | 8082 | `http://localhost:8082/api/v1` |

Use the matching `BASE_URL` in the generated test file. If you cannot determine the project, ask the user.

## Step 1 — Analyze the module

1. Find the router file: `src/module/<module>/router.<module>.js` (or use the path given).
2. Read the **router** to list every endpoint (method, path, middlewares).
3. Read the **validator** to understand every Joi schema (required fields, optional fields, types, allowed values, min/max, regex, enums).
4. Read the **controller** to understand business logic, error cases, and response shapes.
5. Read the **service** if it exists to understand deeper logic, DB queries, and edge conditions.
6. Check the **constant.helper.js** for any enum/constant values referenced by the validator or controller.

## Step 2 — Generate the test file

Create the file at: `tests/<module>.test.js`

Use this exact base template:

```js
const http = require('http');

// Port is determined by which API project this test belongs to:
// api-1 → 8080, api-2 → 8081, api-3 → 8082
const BASE_URL = 'http://localhost:<PORT>/api/v1'; // ← replaced by the detected port

const CREDENTIALS = {
	email: 'crisa@yopmail.com',
	password: '@Tester123',
	role: 3,
};

let accessToken = null;
let refreshToken = null;

// ─── Helpers ────────────────────────────────────────────────────────────────

const colors = {
	green: (t) => `\x1b[32m${t}\x1b[0m`,
	red: (t) => `\x1b[31m${t}\x1b[0m`,
	gray: (t) => `\x1b[90m${t}\x1b[0m`,
};

async function request(method, path, { body, token, query } = {}) {
	const url = new URL(`${BASE_URL}${path}`);
	if (query) {
		Object.entries(query).forEach(([k, v]) => url.searchParams.set(k, v));
	}

	const headers = { 'Content-Type': 'application/json' };
	if (token) headers['Authorization'] = `Bearer ${token}`;

	const payload = body ? JSON.stringify(body) : null;
	if (payload) headers['Content-Length'] = Buffer.byteLength(payload);

	return new Promise((resolve, reject) => {
		const req = http.request(
			{
				hostname: url.hostname,
				port: url.port,
				path: url.pathname + url.search,
				method,
				headers,
			},
			(res) => {
				let data = '';
				res.on('data', (chunk) => (data += chunk));
				res.on('end', () => {
					let parsed;
					try {
						parsed = JSON.parse(data);
					} catch {
						parsed = data;
					}
					resolve({
						status: res.statusCode,
						data: parsed,
						ok: res.statusCode >= 200 && res.statusCode < 300,
					});
				});
			}
		);
		req.on('error', reject);
		if (payload) req.write(payload);
		req.end();
	});
}

function log(label, res) {
	const color = res.ok ? colors.green : colors.red;
	console.log(color(`[${res.status}] ${label}`));
	console.log(colors.gray('   ' + JSON.stringify(res.data, null, 2).replace(/\n/g, '\n   ')));
}

async function login() {
	const res = await request('POST', '/auth/login', {
		body: {
			email_or_phone: CREDENTIALS.email,
			password: CREDENTIALS.password,
			role: CREDENTIALS.role,
		},
	});
	log('POST /auth/login', res);

	if (res.ok && res.data) {
		accessToken = res.data.token || res.data.access_token;
		refreshToken = res.data.refresh_token;
	}

	if (!accessToken) {
		console.log(colors.red('\nLogin failed — cannot continue.'));
		process.exit(1);
	}

	return res;
}
```

## Step 3 — Test categories to cover for EACH endpoint

For every endpoint found in the router, generate tests in this order:

### A. Happy path
- Valid request with all required fields → expect success.
- Valid request with all required + all optional fields → expect success.

### B. Authentication & authorization
- Request **without** token → expect 401/403.
- Request with **expired/invalid** token → expect 401/403.
- If `permitStaffRole` middleware exists: test with a user that does NOT have that role.

### C. Validation — missing required fields
- For each required field in the Joi schema, send a request with that field **removed** → expect 400.

### D. Validation — wrong types
- For each field, send the **wrong type** (string instead of number, number instead of string, object instead of array, etc.) → expect 400.

### E. Validation — boundary values
- Strings: empty string `""`, very long string (10000 chars), string with special chars `<script>alert(1)</script>`.
- Numbers: `0`, negative, float when integer expected, `NaN`, `Infinity`.
- Joi `.valid()` enums: test with a value **outside** the allowed set.
- Joi `.max()` / `.min()`: test at boundary and beyond.
- Joi `.allow(null, '')`: confirm null and empty string are accepted.

### F. Validation — extra/unknown fields
- Send a request with an extra unknown field → check if it's ignored or rejected.

### G. Path parameters
- If route has `:id` param: test with a valid ID, an invalid ID (random UUID), a non-UUID string, empty string.

### H. Query parameters
- Pagination: `page=0`, `page=-1`, `page=999999`, `limit=0`, `limit=-1`, `limit=999999`.
- Sort: invalid `sortColumn`, invalid `sortOrder`.
- Date filters: invalid date formats, `from_date` > `to_date`.

### I. Business logic edge cases
- Read the controller/service code and identify specific error conditions (e.g. "user not found", "already exists", "insufficient balance") and write tests that trigger them if possible.

### J. SQL injection / XSS payloads
- Send typical injection strings in text fields: `' OR 1=1 --`, `<img src=x onerror=alert(1)>`.
- These should NOT crash the server (expect 400 or sanitized response, not 500).

## Step 4 — Structure the output

Group all tests by endpoint inside the `run()` function with clear section headers:

```js
async function run() {
	console.log('WeShake API Test — <MODULE>');
	console.log(`Base URL: ${BASE_URL}`);
	console.log('═'.repeat(60));

	await login();

	// ══════════════════════════════════════════════════════════════
	// POST /auth/login
	// ══════════════════════════════════════════════════════════════

	console.log('\n\n══ POST /auth/login ══');

	// --- Happy path ---
	console.log('\n── Happy path ──');
	// ...tests...

	// --- Missing required fields ---
	console.log('\n── Missing required fields ──');
	// ...tests...

	// --- Wrong types ---
	console.log('\n── Wrong types ──');
	// ...tests...

	// etc.

	console.log('\n' + '═'.repeat(60));
	console.log(colors.green('Done.'));
}
```

## Rules

- **NEVER skip an endpoint.** Every route in the router MUST be tested.
- **NEVER skip a test category.** Every category (A through J) must be attempted for each endpoint.
- Use `log()` for every single request so the user sees colored output.
- Use descriptive labels: `log('POST /auth/login — missing password', res)`.
- If a test creates data (POST), try to clean it up (DELETE) at the end if a delete endpoint exists.
- Store IDs returned by creation endpoints in variables for use in subsequent tests (GET by ID, PUT, DELETE).
- The file must be runnable with `node tests/<module>.test.js` — no external dependencies.
- After generating the file, run it with `node tests/<module>.test.js` and show the output.
