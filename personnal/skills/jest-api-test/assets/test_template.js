const http = require("http");

// Detected from project config — adjust if needed
const BASE_URL = "http://localhost:3000/api/v1"; // ← replaced by the detected base URL

const CREDENTIALS = {
  email: "test@yopmail.com",
  password: "Test1234!",
  role: 1,
};

let accessToken = null;
let refreshToken = null;

// ─── HTTP Helper ───────────────────────────────────────────────────────────────

async function request(method, path, { body, token, query } = {}) {
  const url = new URL(`${BASE_URL}${path}`);
  if (query) {
    Object.entries(query).forEach(([k, v]) => url.searchParams.set(k, v));
  }

  const headers = { "Content-Type": "application/json" };
  if (token) headers["Authorization"] = `Bearer ${token}`;

  const payload = body ? JSON.stringify(body) : null;
  if (payload) headers["Content-Length"] = Buffer.byteLength(payload);

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
        let data = "";
        res.on("data", (chunk) => (data += chunk));
        res.on("end", () => {
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
      },
    );
    req.on("error", reject);
    if (payload) req.write(payload);
    req.end();
  });
}

// ─── Auth Helper ───────────────────────────────────────────────────────────────

async function login() {
  const res = await request("POST", "/auth/login", {
    body: {
      email_or_phone: CREDENTIALS.email,
      password: CREDENTIALS.password,
      role: CREDENTIALS.role,
    },
  });

  if (res.ok && res.data) {
    accessToken = res.data.token || res.data.access_token;
    refreshToken = res.data.refresh_token;
  }

  if (!accessToken) {
    throw new Error("Login failed — cannot continue tests.");
  }

  return res;
}

// ─── Test Suite ────────────────────────────────────────────────────────────────

describe("<MODULE> API", () => {
  beforeAll(async () => {
    await login();
  }, 15000);

  // ══════════════════════════════════════════════════════════════
  // ENDPOINT TESTS GO HERE
  // ══════════════════════════════════════════════════════════════

  // Example structure:
  //
  // describe('POST /module/endpoint', () => {
  //   describe('Happy path', () => {
  //     it('should succeed with all required fields', async () => {
  //       const res = await request('POST', '/module/endpoint', {
  //         body: { field: 'value' },
  //         token: accessToken,
  //       });
  //       expect(res.status).toBe(200);
  //       expect(res.ok).toBe(true);
  //     });
  //   });
  //
  //   describe('Authentication', () => {
  //     it('should return 401 without token', async () => {
  //       const res = await request('POST', '/module/endpoint', {
  //         body: { field: 'value' },
  //       });
  //       expect(res.status).toBe(401);
  //     });
  //   });
  //
  //   describe('Validation — missing required fields', () => {
  //     it('should return 400 when field is missing', async () => {
  //       const res = await request('POST', '/module/endpoint', {
  //         body: {},
  //         token: accessToken,
  //       });
  //       expect(res.status).toBe(400);
  //     });
  //   });
  // });
});
