# Why not read glab's token

The shortcut for a GitLab desktop app is obvious: `glab` is already
authenticated, so read whatever it stored and skip the login flow entirely.

This app doesn't, and the reason isn't purity.

**It wouldn't have worked.** `glab`'s config holds an OAuth2 *refresh* token,
not a static credential:

```yaml
token: NULL
is_oauth2: true
oauth2_refresh_token: <present>
oauth2_expiry_date: 2026-08-23T02:30:32   # ~2 hours out
```

Using it would mean reimplementing GitLab's token refresh in Swift, against an
undocumented file format that upstream can change whenever it likes. More work
than doing it properly, for a worse result.

The other two reasons matter too. Reading another application's private
credential store is indistinguishable from malware in a public repo, and file
schemas that nobody promised to keep stable will eventually break.

So: you create a `read_api` token, it goes in the macOS Keychain, and the app
talks to GitLab's GraphQL API over `URLSession`. The keychain prompt on first
launch is a feature — the app can't reach your credential without you agreeing.

Minting a token programmatically isn't an option either. GitLab rejects it:

```
POST /user/personal_access_tokens
{"error":"scopes does not have a valid value"}   HTTP 400
```

Which is correct of them. A token shouldn't be able to mint another token.

## The keychain has two backends

The modern data-protection keychain needs entitlements that an ad-hoc signed app
doesn't have:

```
SecItemAdd(kSecUseDataProtectionKeychain: true)  →  -34018  errSecMissingEntitlement
```

That requires a paid Developer ID. So the app tries the data-protection keychain
first and falls back to the legacy one, which works today and upgrades silently
if the app is ever properly signed.

## Why `make signing-identity` exists

An ad-hoc signature's designated requirement is the binary's own hash:

```
designated => cdhash H"aee7ba65..."
```

That hash changes on every single build:

```
before: c6c64e72bfbd48ed1e59535132b7898146b2cfde
after:  34133ebc2102f5eac9915496c66e2c3dbeb05f40
```

The keychain ACL matches on it, so macOS treats each rebuild as a brand new
application and asks for your password again. "Always Allow" only ever
authorises the exact build you clicked it on — which during development means a
password prompt every few minutes.

`make signing-identity` creates a local self-signed certificate. The requirement
then keys off the certificate instead, which survives rebuilds. One prompt, once.

It's a development certificate: not a Developer ID, no notarization, nothing
leaves your machine.
