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

function loadAdminPassword() {
  if (process.env.KC_ADMIN_PASSWORD) return process.env.KC_ADMIN_PASSWORD.trim();
  const envFile = resolve(repoRoot, 'secrets/keycloak-admin.env');
  if (existsSync(envFile)) {
    const text = readFileSync(envFile, 'utf8');
    const m = text.match(/^KC_ADMIN_PASSWORD=(.*)$/m);
    if (m) return m[1].trim();
  }
  const b64 = execSync(
    "oc get secret keycloak-initial-admin -n rhbk-mc -o jsonpath='{.data.password}'",
    { encoding: 'utf8' }
  ).trim();
  return Buffer.from(b64, 'base64').toString('utf8');
}

const adminPassword = loadAdminPassword();
const baseUrl = cfg.keycloak.url;
const admin = new KcAdminClient({ baseUrl, realmName: 'master' });

await admin.auth({
  username: process.env.KC_ADMIN_USER || 'temp-admin',
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
if (clients.length === 0) {
  await admin.clients.create(desired.client);
  console.log(`Created client ${desired.client.clientId}`);
} else {
  const id = clients[0].id;
  await admin.clients.update({ id }, { ...desired.client, id });
  console.log(`Updated client ${desired.client.clientId}`);
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
