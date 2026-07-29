import express from 'express';
import https from 'node:https';

const app = express();
const port = Number(process.env.PORT || 8080);
const AUTH_URL = process.env.AUTH_URL || 'https://auth.lan.local:8443';
const insecureAgent = new https.Agent({ rejectUnauthorized: false });

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

app.listen(port, () => {
  console.log(`PoC SPA listening on http://localhost:${port}`);
  console.log(`Auth server: ${AUTH_URL} (poc-realm / poc-spa)`);
  console.log(`Health proxy: http://localhost:${port}/api/lb-check`);
});
