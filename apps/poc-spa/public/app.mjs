import Keycloak from "keycloak-js";

const AUTH_URL = "https://auth.lan.local:8443";
const REALM = "poc-realm";
const CLIENT_ID = "poc-spa";
const LB_CHECK = `${AUTH_URL}/lb-check`;

const els = {
  session: document.getElementById("session"),
  greeting: document.getElementById("greeting"),
  issuer: document.getElementById("issuer"),
  roles: document.getElementById("roles"),
  expiry: document.getElementById("expiry"),
  statusChip: document.getElementById("statusChip"),
  login: document.getElementById("login"),
  logout: document.getElementById("logout"),
  refreshToken: document.getElementById("refreshToken"),
  showIdToken: document.getElementById("showIdToken"),
  showAccessToken: document.getElementById("showAccessToken"),
  showMyAccount: document.getElementById("showMyAccount"),
  checkHealth: document.getElementById("checkHealth"),
  healthChip: document.getElementById("healthChip"),
  recoveryHint: document.getElementById("recoveryHint"),
  tokenPanel: document.getElementById("tokenPanel"),
  tokenTitle: document.getElementById("tokenTitle"),
  output: document.getElementById("output"),
  hideToken: document.getElementById("hideToken"),
};

let expiryTimer;

function setChip(el, state, text) {
  el.dataset.state = state;
  el.textContent = text;
}

function showToken(title, content) {
  els.tokenTitle.textContent = title;
  els.output.textContent =
    typeof content === "object" ? JSON.stringify(content, null, 2) : String(content);
  els.tokenPanel.hidden = false;
}

function rolesFromToken(parsed) {
  const realm = parsed?.realm_access?.roles || [];
  return realm.filter((r) => !["default-roles-poc-realm", "offline_access", "uma_authorization"].includes(r));
}

function formatExpiry(parsed) {
  if (!parsed?.exp) return "—";
  const ms = parsed.exp * 1000 - Date.now();
  if (ms <= 0) return "expired";
  const s = Math.floor(ms / 1000);
  const m = Math.floor(s / 60);
  const rem = s % 60;
  return m > 0 ? `${m}m ${rem}s` : `${rem}s`;
}

function refreshExpiryLabel() {
  els.expiry.textContent = formatExpiry(keycloak.tokenParsed);
}

function showProfile() {
  const name =
    keycloak.idTokenParsed?.name ||
    keycloak.idTokenParsed?.preferred_username ||
    "user";
  els.greeting.textContent = `Hello ${name}`;
  els.issuer.textContent = keycloak.tokenParsed?.iss || "—";
  const roles = rolesFromToken(keycloak.tokenParsed);
  els.roles.textContent = roles.length ? roles.join(", ") : "(none)";
  refreshExpiryLabel();
  clearInterval(expiryTimer);
  expiryTimer = setInterval(refreshExpiryLabel, 1000);

  els.session.hidden = false;
  els.login.hidden = true;
  els.logout.hidden = false;
  els.refreshToken.hidden = false;
  els.showIdToken.hidden = false;
  els.showAccessToken.hidden = false;
  els.showMyAccount.hidden = false;
  setChip(els.statusChip, "ok", "Signed in");
}

function showLoggedOut() {
  els.session.hidden = true;
  els.tokenPanel.hidden = true;
  els.login.hidden = false;
  els.logout.hidden = true;
  els.refreshToken.hidden = true;
  els.showIdToken.hidden = true;
  els.showAccessToken.hidden = true;
  els.showMyAccount.hidden = true;
  setChip(els.statusChip, "idle", "Signed out");
  els.recoveryHint.textContent = "Log in, then run a site failover and use Refresh token.";
}

els.login.addEventListener("click", () => keycloak.login());
els.logout.addEventListener("click", () => keycloak.logout({ redirectUri: window.location.origin + "/" }));
els.showIdToken.addEventListener("click", () => showToken("ID token", keycloak.idTokenParsed));
els.showAccessToken.addEventListener("click", () => showToken("Access token", keycloak.tokenParsed));
els.showMyAccount.addEventListener("click", () => keycloak.accountManagement());
els.hideToken.addEventListener("click", () => {
  els.tokenPanel.hidden = true;
});

els.refreshToken.addEventListener("click", async () => {
  try {
    const refreshed = await keycloak.updateToken(-1);
    showProfile();
    setChip(
      els.statusChip,
      "ok",
      refreshed ? "Token refreshed" : "Token still valid"
    );
    els.recoveryHint.textContent = `Refresh ok at ${new Date().toLocaleTimeString()} — issuer unchanged.`;
    showToken("Access token (after refresh)", keycloak.tokenParsed);
  } catch (err) {
    setChip(els.statusChip, "err", "Refresh failed");
    els.recoveryHint.textContent =
      "Refresh failed. If both sites are down or HAProxy is stopped, bring one site back and log in again.";
    console.error(err);
  }
});

els.checkHealth.addEventListener("click", async () => {
  try {
    const res = await fetch(LB_CHECK, { cache: "no-store" });
    const body = (await res.text()).trim();
    if (res.ok && body === "UP") {
      setChip(els.healthChip, "ok", "Auth LB UP");
      els.recoveryHint.textContent = "HAProxy /lb-check returned UP.";
    } else {
      setChip(els.healthChip, "err", `Unexpected: ${res.status} ${body}`);
      els.recoveryHint.textContent = "Auth health check did not return UP.";
    }
  } catch (err) {
    setChip(els.healthChip, "err", "Unreachable");
    els.recoveryHint.textContent =
      "Could not reach auth.lan.local:8443. Check hosts file and HAProxy.";
    console.error(err);
  }
});

const keycloak = new Keycloak({
  url: AUTH_URL,
  realm: REALM,
  clientId: CLIENT_ID,
});

try {
  const authenticated = await keycloak.init({
    onLoad: "check-sso",
    pkceMethod: "S256",
    checkLoginIframe: false,
  });
  if (authenticated) {
    showProfile();
    els.recoveryHint.textContent =
      "Tip: oc delete pod keycloak-0 -n rhbk-mc on Linux, then Refresh token.";
  } else {
    showLoggedOut();
  }
} catch (err) {
  showLoggedOut();
  setChip(els.healthChip, "err", "Init failed");
  els.recoveryHint.textContent =
    "Keycloak init failed. Confirm auth.lan.local resolves to 192.168.0.114 and the SPA client exists.";
  console.error(err);
}
