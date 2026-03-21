const http = require("http");

// Port is determined by which API project this test belongs to:
// api-1 → 8080, api-2 → 8081, api-3 → 8082
const BASE_URL = "http://localhost:<PORT>/api/v1"; // ← replaced by the detected port

const CREDENTIALS = {
  email: "crisa@yopmail.com",
  password: "@Tester123",
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

function log(label, res) {
  const color = res.ok ? colors.green : colors.red;
  console.log(color(`[${res.status}] ${label}`));
  console.log(
    colors.gray(
      "   " + JSON.stringify(res.data, null, 2).replace(/\n/g, "\n   "),
    ),
  );
}

async function login() {
  const res = await request("POST", "/auth/login", {
    body: {
      email_or_phone: CREDENTIALS.email,
      password: CREDENTIALS.password,
      role: CREDENTIALS.role,
    },
  });
  log("POST /auth/login", res);

  if (res.ok && res.data) {
    accessToken = res.data.token || res.data.access_token;
    refreshToken = res.data.refresh_token;
  }

  if (!accessToken) {
    console.log(colors.red("\nLogin failed — cannot continue."));
    process.exit(1);
  }

  return res;
}
