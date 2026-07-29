import express from 'express';
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, '../..');

const app = express();
const httpPort = Number(process.env.PORT || 8080);
const httpsPort = Number(process.env.HTTPS_PORT || 8444);
const AUTH_URL = process.env.AUTH_URL || 'https://auth.lan.local:8443';
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

// Static tree includes vendored keycloak-js at public/vendor/keycloak.js
app.use('/', express.static('public'));

http.createServer(app).listen(httpPort, () => {
  console.log(`PoC SPA HTTP  http://localhost:${httpPort}  (Web Crypto: localhost only)`);
  console.log(`Auth server: ${AUTH_URL} (poc-realm / poc-spa)`);
});

if (fs.existsSync(tlsCert) && fs.existsSync(tlsKey)) {
  const creds = {
    cert: fs.readFileSync(tlsCert),
    key: fs.readFileSync(tlsKey),
  };
  https.createServer(creds, app).listen(httpsPort, () => {
    console.log(
      `PoC SPA HTTPS https://192.168.0.114:${httpsPort}  (use this from Windows — secure context / Web Crypto)`
    );
  });
} else {
  console.warn(
    `No TLS certs at ${tlsCert} / ${tlsKey}; LAN browsers cannot use PKCE on plain http://IP:port`
  );
}
