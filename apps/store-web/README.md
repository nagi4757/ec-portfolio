# Store Web

## Local configuration

Run the following from the repository root for initial setup. Keep an existing local env file rather than overwriting it.

```sh
npm ci
cp apps/store-web/.env.example apps/store-web/.env.local
npm run dev --workspace=store-web
```

The dev UI is at `http://localhost:5174` (Vite binds to `127.0.0.1`, with a strict port).
With an empty `VITE_API_BASE_URL`, requests use relative `/api/...` paths and Vite proxies them to `http://127.0.0.1:8081`.

For a direct API connection, edit this app's ignored `.env.local`:

```dotenv
# Documentation placeholder only; replace locally with the approved HTTPS API origin.
VITE_API_BASE_URL=https://api.example.invalid
```

- Use the API **origin only**, without `/api`, a query string, credentials, or a fragment. Whitespace around the value and trailing slashes are removed by the client.
- This setting belongs to the app; the repository-root Docker Compose `.env` does not configure Vite.
- Vite embeds `VITE_*` values into the browser bundle. They are public, not secret storage. Do not add passwords, JWTs, AWS credentials, or origin-verification tokens.
- Never commit the actual deployment URL or local env files. Only `.env.example` is tracked.
- Restart the dev server after changing env files. For production, set the value before building (for example in this app's ignored `.env.production.local`) and rebuild; changing the server environment cannot update an existing bundle.
- The dev proxy is not included in `dist`. An empty production base requires a separately provided same-origin `/api` reverse proxy. Otherwise configure an explicit API origin.

## API and authentication assumptions

The client sends `Authorization: Bearer <token>` when a saved token exists, and `Content-Type: application/json` for JSON request bodies. It does not enable cross-origin cookie credentials.

Store requests use the saved login token. USER and ADMIN access to user APIs is decided by the backend.

A 401 from a protected request clears the session and redirects to `/login` only when its original, non-empty token still matches the current token. A late 401 cannot clear a newer login. Failed login/signup requests stay on the form; 403 does not clear the session.

The client accepts successful JSON responses, including 201, and returns no value for 204. Cart mutations still use their existing 200 JSON response. HTML 200 responses, malformed JSON, and empty non-204 responses are errors, not application data. Typed API errors preserve HTTP status, error code, and correlation ID when available without exposing the raw response body in error messages.

For direct browser-to-API access, verify that the deployed API/gateway:

- Allows the exact frontend Origin, including scheme and port. `localhost` and `127.0.0.1` are different origins.
- Allows OPTIONS preflight, the requested method, `Authorization`, and `Content-Type`.
- Exposes `X-Correlation-ID` if clients need to read it, and preserves CORS headers on error responses.
- Forwards authorization and does not share/cache personalized responses between users.

Do not bypass CORS with `no-cors` or place any gateway verification secret in the frontend.

## Offline verification

With dependencies already installed, these commands need no API server:

```sh
npm run lint --workspace=store-web
npm run build --workspace=store-web
```

Build runs `tsc -b` before Vite. It checks TypeScript and creates `apps/store-web/dist`; it does not verify network connectivity or server behavior.

## Live integration checklist

- Product list/detail: loading, empty, not-found, and inactive product handling.
- Signup/login: success, duplicate email, wrong credentials, connection failure, and expired sessions.
- Cart: stock limits, inactive items, removal, and no per-product detail requests.
- Checkout: required shipping address, order creation, insufficient stock, and failure feedback.
- Order list/detail: shipping snapshot, legacy null address, permitted cancellation, and 409 feedback.
- Check Network for the configured API origin, CORS preflight, Bearer headers, and JSON/204 responses.
- Check expired-token 401, role-related 403, and network/5xx failure feedback.
- Verify ja/ko switching for the added error messages and unchanged navigation.
- Refresh a nested route directly; the frontend host must support SPA history fallback without rewriting API errors to HTML.

Use dummy test accounts only. Do not include tokens, addresses, passwords, or raw private responses in reports or shared logs.
