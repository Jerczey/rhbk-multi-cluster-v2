import express from 'express';
import url from 'node:url';

const app = express();
const port = Number(process.env.PORT || 8080);

app.use('/', express.static('public'));
app.use('/vendor/keycloak.js', express.static(resolveDependency('keycloak-js')));

app.listen(port, () => {
  console.log(`PoC SPA listening on http://localhost:${port}`);
  console.log(`Auth server: https://auth.lan.local:8443 (poc-realm / poc-spa)`);
});

function resolveDependency(module) {
  return url.fileURLToPath(import.meta.resolve(module));
}
