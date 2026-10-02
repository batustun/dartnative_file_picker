# Security policy

## Reporting a vulnerability

Please report security vulnerabilities **privately**, not in a public issue.

Use GitHub's private vulnerability reporting on this repository:

1. Go to <https://github.com/batustun/dartnative_file_picker/security/advisories>
2. Click **Report a vulnerability**

That form is private to the maintainers. Please include what you were doing, what
happened, the platform and OS version, and a reproduction if you have one.

Expect an acknowledgement within a few days. There is no bug bounty.

> **Maintainer setup note.** Private reporting must be switched on once, under
> *Settings → Advanced Security → Private vulnerability reporting*, before the
> link above accepts submissions. Do that before announcing the package.

## Supported versions

0.1.0 is pre-1.0 and only the latest release receives fixes.

## What this package does, from a security standpoint

Useful context when judging whether something is a vulnerability:

- **No permissions are declared** on either platform. Access comes from the
  Storage Access Framework grant on the document the user picked, and from iOS
  security-scoped resources.
- **No network code.** Nothing is uploaded, and there is no network dependency.
- **No analytics or telemetry.**
- **Documents are opened read-only.** Nothing is executed, and no document is
  interpreted beyond reading its bytes.
- **Provider metadata is untrusted.** Display name, size and MIME type come from
  a `DocumentsProvider` and are validated: a reported path is accepted only when
  absolute, and `mimeType` is documented as unsuitable for a security decision.
- **Filenames are sanitized before any write.** `copyToCache()` strips path
  separators, `..`, control characters and leading dots, caps the length, writes
  into a fresh unique directory, and verifies the canonical destination is inside
  that directory before copying.
- **Security scopes are balanced.** Every successful
  `startAccessingSecurityScopedResource()` has a matching `stop…`, and read
  handles are closed on completion, cancellation and failure.
- **Persisted access is explicit and revocable**, requested only with
  `persistAccess: true` and released by `releasePersistedAccess()`.
- **Android URI grants are bounded by construction.** `AccessMode.reference`
  takes a persistable grant on every picked document, because a transient
  activity-result grant does not outlive the picker's activity and the document
  would otherwise be unreadable by the time Dart could read it. Grants taken
  without `persistAccess: true` are recorded in a private ledger and released
  automatically, on the next process start and on engine detach, so no grant
  outlives the session that asked for it. The ledger also evicts its own oldest
  entry past 256, which keeps the app clear of Android's 512-grant cap and the
  silent oldest-first pruning that comes with it. A grant the plugin takes is
  always for a document the user picked in the system picker; no grant is ever
  taken for a URI that came from anywhere else. Only
  `FLAG_GRANT_READ_URI_PERMISSION` is ever taken, never write, even though
  DocumentsUI offers both: the package has no write API, and taking the write
  half made the grant impossible to give back in full, since the release call
  names read.

Things that would be worth reporting: a way to make `copyToCache()` write outside
the cache directory, a leaked security scope or URI grant, a path returned for a
document that has none, or any way to read a document the user did not pick.
