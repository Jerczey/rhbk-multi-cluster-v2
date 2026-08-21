import express from 'express';
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRemoteJWKSet, jwtVerify } from 'jose';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '../..');

const app = express();
const httpPort = Number(process.env.PORT || 8080);
const httpsPort = Number(process.env.HTTPS_PORT || 8444);
const AUTH_URL = process.env.AUTH_URL || 'https://auth.lan.local:8443';
const REALM = process.env.REALM || 'poc-realm';
const ISSUER = `${AUTH_URL}/realms/${REALM}`;
const JWKS = createRemoteJWKSet(new URL(`${ISSUER}/protocol/openid-connect/certs`));
const insecureAgent = new https.Agent({ rejectUnauthorized: false });

const tlsCert =
  process.env.TLS_CERT || path.join(root, 'secrets/tls.crt');
const tlsKey =
  process.env.TLS_KEY || path.join(root, 'secrets/tls.key');

app.get('/api/lb-check', async (_req, res) => {
  try {
    const { statusCode, body } = await new Promise((resolve, reject) => {
      const req = https.get(
        `${AUTH_URL}/lb-check`,
        { agent: insecureAgent, timeout: 5000 },
        (r) => {
          let data = '';
          r.setEncoding('utf8');
          r.on('data', (c) => (data += c));
          r.on('end', () => resolve({ statusCode: r.statusCode || 502, body: data.trim() }));
        }
      );
      req.on('error', reject);
      req.on('timeout', () => {
        req.destroy();
        reject(new Error('timeout'));
      });
    });
    res.status(statusCode).type('text/plain').send(body);
  } catch (err) {
    console.error('lb-check proxy failed:', err.message);
    res.status(502).type('text/plain').send(`DOWN: ${err.message}`);
  }
});

app.get('/api/protected/profile', async (req, res) => {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) {
    res.status(401).json({ error: 'missing bearer token' });
    return;
  }
  try {
    const { payload } = await jwtVerify(token, JWKS, { issuer: ISSUER });
    res.json({
      username: payload.preferred_username || payload.sub,
      roles: (payload.realm_access?.roles || []).filter(
        (r) => !['default-roles-poc-realm', 'offline_access', 'uma_authorization'].includes(r)
      ),
      exp: payload.exp,
      azp: payload.azp,
    });
  } catch (err) {
    res.status(401).json({ error: 'invalid token', detail: err.message });
  }
});

// Static tree includes vendored keycloak-js at public/vendor/keycloak.js
app.use('/', express.static('public'));

http.createServer(app).listen(httpPort, () => {
  console.log(`PoC SPA HTTP  http://localhost:${httpPort}  (Web Crypto: localhost only)`);
  console.log(`Auth server: ${AUTH_URL} (${REALM} / poc-spa)`);
});

if (process.env.SPA_SKIP_HTTPS !== '1' && process.env.SPA_SKIP_HTTPS !== 'true'
    && fs.existsSync(tlsCert) && fs.existsSync(tlsKey)) {
  const creds = {
    cert: fs.readFileSync(tlsCert),
    key: fs.readFileSync(tlsKey),
  };
  https.createServer(creds, app).listen(httpsPort, () => {
    console.log(
      `PoC SPA HTTPS https://auth.lan.local:${httpsPort}  (preferred from Windows — secure context / Web Crypto)`
    );
    console.log(`Also: https://${process.env.PRIMARY_HOST || '192.168.0.114'}:${httpsPort}`);
  });
} else {
  console.warn(
    `No TLS certs at ${tlsCert} / ${tlsKey}; LAN browsers cannot use PKCE on plain http://IP:port`
  );
}
