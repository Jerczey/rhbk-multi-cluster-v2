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
  if (payload.attributes) {
    const attrs = { ...payload.attributes };
    if (attrs['standard.token.exchange.enable'] === 'true') {
      attrs['standard.token.exchange.enabled'] = 'true';
      delete attrs['standard.token.exchange.enable'];
    }
    payload.attributes = attrs;
  }
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

async function findClientScopeByName(scopeName) {
  const scopes = await admin.clientScopes.find({ search: scopeName, max: 50 });
  const exact = scopes.find((s) => s.name === scopeName);
  if (exact) return exact;
  const all = await admin.clientScopes.find({ max: 200 });
  return all.find((s) => s.name === scopeName);
}

async function ensureClientScope(scopeName, description) {
  let scope = await findClientScopeByName(scopeName);
  if (scope) return scope;
  try {
    const created = await admin.clientScopes.create({
      name: scopeName,
      protocol: 'openid-connect',
      description,
    });
    console.log(`Created client scope ${scopeName}`);
    return { id: created.id, name: scopeName };
  } catch (err) {
    const msg = err?.responseData?.errorMessage || err?.message || String(err);
    if (msg.includes('already exists')) {
      scope = await findClientScopeByName(scopeName);
      if (scope) return scope;
    }
    throw err;
  }
}

async function ensureExchangeTargetAudienceScope() {
  const scopeName = 'poc-exchange-target-audience';
  const targetClientId = 'poc-exchange-target';
  const requesterClientId = 'poc-exchange-requester';
  const mapperName = 'poc-exchange-target-audience-mapper';

  const scope = await ensureClientScope(
    scopeName,
    'Adds poc-exchange-target to access token audience for V2 token exchange tests'
  );
  const scopeId = scope.id || (await findClientScopeByName(scopeName))?.id;
  if (!scopeId) throw new Error(`Client scope ${scopeName} missing id`);

  const mappers = await admin.clientScopes.listProtocolMappers({ id: scopeId });
  if (!mappers.some((m) => m.name === mapperName)) {
    try {
      await admin.clientScopes.addProtocolMapper(
        { id: scopeId },
        {
          name: mapperName,
          protocol: 'openid-connect',
          protocolMapper: 'oidc-audience-mapper',
          config: {
            'included.client.audience': targetClientId,
            'id.token.claim': 'false',
            'access.token.claim': 'true',
          },
        }
      );
      console.log(`Added audience mapper on ${scopeName}`);
    } catch (err) {
      const msg = err?.responseData?.errorMessage || err?.message || String(err);
      if (!msg.includes('Protocol mapper exists with same name')) throw err;
      console.log(`Audience mapper ${mapperName} already present on ${scopeName}`);
    }
  }

  const requester = (await admin.clients.find({ clientId: requesterClientId }))[0];
  if (!requester?.id) {
    console.warn(`Skip audience scope attach: ${requesterClientId} not found`);
    return;
  }
  const defaults = await admin.clients.listDefaultClientScopes({ id: requester.id });
  if (!defaults.some((s) => s.name === scopeName)) {
    await admin.clients.addDefaultClientScope({ id: requester.id, clientScopeId: scopeId });
    console.log(`Attached ${scopeName} to ${requesterClientId}`);
  }
}

async function ensureClientAudienceMapper(clientInternalId, mapperName, audienceClientId) {
  const mappers = await admin.clients.listProtocolMappers({ id: clientInternalId });
  if (mappers.some((m) => m.name === mapperName)) return;
  await admin.clients.addProtocolMapper(
    { id: clientInternalId },
    {
      name: mapperName,
      protocol: 'openid-connect',
      protocolMapper: 'oidc-audience-mapper',
      config: {
        'included.client.audience': audienceClientId,
        'id.token.claim': 'false',
        'access.token.claim': 'true',
      },
    }
  );
  console.log(`Added audience mapper ${mapperName} on client ${audienceClientId}`);
}

async function ensureClientScopeAudienceMapper(scopeId, mapperName, audienceClientId) {
  const mappers = await admin.clientScopes.listProtocolMappers({ id: scopeId });
  if (mappers.some((m) => m.name === mapperName)) return;
  try {
    await admin.clientScopes.addProtocolMapper(
      { id: scopeId },
      {
        name: mapperName,
        protocol: 'openid-connect',
        protocolMapper: 'oidc-audience-mapper',
        config: {
          'included.client.audience': audienceClientId,
          'id.token.claim': 'false',
          'access.token.claim': 'true',
        },
      }
    );
    console.log(`Added audience mapper ${mapperName} on scope for ${audienceClientId}`);
  } catch (err) {
    const msg = err?.responseData?.errorMessage || err?.message || String(err);
    if (msg.includes('Protocol mapper exists with same name')) {
      console.log(`Audience mapper ${mapperName} already present on scope`);
      return;
    }
    throw err;
  }
}

async function ensureSourceAudienceForV1() {
  const sourceClientId = 'poc-exchange-source';
  const scopeName = 'poc-exchange-v1-audiences';

  const scope = await ensureClientScope(scopeName, 'Audiences for legacy V1 token exchange');
  const scopeId = scope.id || (await findClientScopeByName(scopeName))?.id;
  if (!scopeId) throw new Error(`Client scope ${scopeName} missing id`);
  await ensureClientScopeAudienceMapper(scopeId, 'v1-audience-requester', 'poc-exchange-requester');
  await ensureClientScopeAudienceMapper(scopeId, 'v1-audience-target', 'poc-exchange-target');

  const source = (await admin.clients.find({ clientId: sourceClientId }))[0];
  if (!source?.id) return;
  const defaults = await admin.clients.listDefaultClientScopes({ id: source.id });
  if (!defaults.some((s) => s.name === scopeName)) {
    await admin.clients.addDefaultClientScope({ id: source.id, clientScopeId: scopeId });
    console.log(`Attached ${scopeName} to ${sourceClientId}`);
  }
}

async function ensureLegacyTokenExchangePermission() {
  const target = (await admin.clients.find({ clientId: 'poc-exchange-target' }))[0];
  const requester = (await admin.clients.find({ clientId: 'poc-exchange-requester' }))[0];
  if (!target?.id || !requester?.id) return;

  try {
    await admin.clients.updateFineGrainPermission({ id: target.id }, { enabled: true });
    const perms = await admin.clients.listFineGrainPermissions({ id: target.id });
    const tokenExchangePermId = perms.scopePermissions?.['token-exchange'];
    if (tokenExchangePermId) {
      console.log(
        `Legacy V1: token-exchange permission id=${tokenExchangePermId} on ${target.clientId} (grant ${requester.clientId} in Admin Console if V1 tests fail)`
      );
    }
  } catch (err) {
    console.warn(`Legacy V1 FGAP setup skipped: ${err.message || err}`);
  }
}

await ensureExchangeTargetAudienceScope();
await ensureSourceAudienceForV1();
await ensureLegacyTokenExchangePermission();

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
