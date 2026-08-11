#!/usr/bin/env node
/**
 * Ensure poc-realm has poc-spa client, roles, and test users.
 * Password from KC_ADMIN_PASSWORD, secrets/keycloak-admin.env, or oc secret (base64).
 */
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execSync } from 'node:child_process';
import KcAdminClient from '@keycloak/keycloak-admin-client';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = resolve(__dirname, '..');
const repoRoot = resolve(root, '../..');
const cfg = JSON.parse(readFileSync(resolve(root, 'config/config.json'), 'utf8'));
const desired = JSON.parse(readFileSync(resolve(root, 'config/realm-clients.json'), 'utf8'));

function lanHost() {
  const pgEnv = resolve(repoRoot, 'secrets/postgres.env');
  if (existsSync(pgEnv)) {
    const m = readFileSync(pgEnv, 'utf8').match(/^PRIMARY_HOST=(.*)$/m);
    if (m) return m[1].trim();
  }
  return process.env.PRIMARY_HOST || '127.0.0.1';
}

function mergeRedirectUris(uris) {
  const host = lanHost();
  const extra = [`http://${host}:8080/*`, `https://${host}:8444/*`];
  return [...new Set([...(uris || []), ...extra])];
}

function mergeWebOrigins(origins) {
  const host = lanHost();
  const extra = [
    'http://localhost:8080',
    `http://${host}:8080`,
    'https://auth.lan.local:8444',
  ];
  return [...new Set([...(origins || []), ...extra])];
}

function loadAdminEnv() {
  const out = {};
  if (process.env.KC_ADMIN_USER) out.user = process.env.KC_ADMIN_USER.trim();
  if (process.env.KC_ADMIN_PASSWORD) out.password = process.env.KC_ADMIN_PASSWORD.trim();
  const envFile = resolve(repoRoot, 'secrets/keycloak-admin.env');
  if (existsSync(envFile)) {
    const text = readFileSync(envFile, 'utf8');
    const user = text.match(/^KC_ADMIN_USER=(.*)$/m);
    const pass = text.match(/^KC_ADMIN_PASSWORD=(.*)$/m);
    if (!out.user && user) out.user = user[1].trim();
    if (!out.password && pass) out.password = pass[1].trim();
  }
  if (!out.password) {
    const b64 = execSync(
      "oc get secret keycloak-initial-admin -n rhbk-mc -o jsonpath='{.data.password}'",
      { encoding: 'utf8' }
    ).trim();
    out.password = Buffer.from(b64, 'base64').toString('utf8');
  }
  out.user = out.user || 'temp-admin';
  return out;
}

const { user: adminUser, password: adminPassword } = loadAdminEnv();
const baseUrl = cfg.keycloak.url;
const admin = new KcAdminClient({ baseUrl, realmName: 'master' });

await admin.auth({
  username: adminUser,
  password: adminPassword,
  grantType: 'password',
  clientId: 'admin-cli',
});

const realm = cfg.keycloak.realm;
admin.setConfig({ realmName: realm });

const existingRoles = await admin.roles.find();
const existingRoleNames = new Set(existingRoles.map((r) => r.name));
for (const role of desired.roles) {
  if (!existingRoleNames.has(role.name)) {
    await admin.roles.create(role);
    console.log(`Created role ${role.name}`);
  }
}

const clients = await admin.clients.find({ clientId: desired.client.clientId });
const spaClient = {
  ...desired.client,
  redirectUris: mergeRedirectUris(desired.client.redirectUris),
  webOrigins: mergeWebOrigins(desired.client.webOrigins),
};
if (clients.length === 0) {
  await admin.clients.create(spaClient);
  console.log(`Created client ${spaClient.clientId}`);
} else {
  const id = clients[0].id;
  await admin.clients.update({ id }, { ...spaClient, id });
  console.log(`Updated client ${spaClient.clientId}`);
}

async function upsertClient(def) {
  const redirectUris = def.redirectUris ? mergeRedirectUris(def.redirectUris) : undefined;
  const webOrigins =
    def.webOrigins?.[0] === '+'
      ? def.webOrigins
      : def.webOrigins
        ? mergeWebOrigins(def.webOrigins)
        : undefined;
  const payload = {
    ...def,
    ...(redirectUris ? { redirectUris } : {}),
    ...(webOrigins ? { webOrigins } : {}),
  };
  delete payload.secret;
  const found = await admin.clients.find({ clientId: def.clientId });
  if (found.length === 0) {
    await admin.clients.create(payload);
    console.log(`Created client ${def.clientId}`);
  } else {
    await admin.clients.update({ id: found[0].id }, { ...payload, id: found[0].id });
    console.log(`Updated client ${def.clientId}`);
  }
  if (def.secret) {
    const cid = found[0]?.id || (await admin.clients.find({ clientId: def.clientId }))[0]?.id;
    if (cid) {
      await admin.clients.update({ id: cid }, { secret: def.secret });
    }
  }
}

for (const extra of desired.additionalClients || []) {
  await upsertClient(extra);
}

for (const user of desired.users) {
  const found = await admin.users.find({ username: user.username, exact: true });
  let userId;
  if (found.length === 0) {
    const created = await admin.users.create({
      username: user.username,
      enabled: user.enabled,
      email: user.email,
      firstName: user.firstName,
      lastName: user.lastName,
      emailVerified: user.emailVerified,
      credentials: user.credentials,
    });
    userId = created.id;
    console.log(`Created user ${user.username}`);
  } else {
    userId = found[0].id;
    await admin.users.update(
      { id: userId },
      {
        enabled: user.enabled,
        email: user.email,
        firstName: user.firstName,
        lastName: user.lastName,
        emailVerified: user.emailVerified,
      }
    );
    if (user.credentials?.[0]) {
      await admin.users.resetPassword({
        id: userId,
        credential: user.credentials[0],
      });
    }
    console.log(`Updated user ${user.username}`);
  }

  const realmRoles = [];
  for (const name of user.realmRoles || []) {
    const role = await admin.roles.findOneByName({ name });
    if (role) realmRoles.push({ id: role.id, name: role.name });
  }
  if (realmRoles.length) {
    await admin.users.addRealmRoleMappings({ id: userId, roles: realmRoles });
  }
}

console.log(`Realm ${realm} ready for SPA at ${baseUrl}`);
