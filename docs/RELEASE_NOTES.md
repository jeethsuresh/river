# River 0.7.1

- Automatically renew expiring Gravitas access credentials within the original central session, avoiding hourly login and native device-link prompts.
- Persist renewed Android credentials in secure storage and browser credentials in the existing encrypted HttpOnly cookie.
- Reconnect live updates after access-token expiry and preserve saved credentials during temporary outages.
- Save Matrix credentials immediately when initial reconnect sync rotates them, retaining the same device store and encryption keys.
- Older versions discarded refresh tokens, so sign in once after updating to enable renewal. Central logout, permission revocation and the original session limit (up to 30 days) still apply.

Uses the existing permanent River Android signing certificate and package.
