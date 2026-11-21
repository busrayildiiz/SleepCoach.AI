# Private data storage and cloud coaching

## Scope and branch boundary

This change is on `fix/security-sensitive-data`, based on main
`4e7595a5ac157ae84d4dd3f9875546d067494f6c`. It addresses the three CodeQL
`swift/cleartext-storage-preferences` findings and the other personal-data
storage and transmission paths in the current app.

PR #34, `fix/stale-sleep-routine-planning`, has already been merged into that
main revision. The security-only patch was recovered from the reviewed package,
its SHA-256 was verified, and it applied cleanly to the merged main. The final
PR #34 caption and native UI-test fixes remain intact. This branch contains
only the additional security changes, their tests/documentation, and the
registration of `PrivacyUITests` in the existing CI suite allowlist.

The owner explicitly approved discarding the existing development/demo data.
There is no legacy personal-data migration. This decision does not authorize
discarding future user records after a storage error.

## Data inventory

| Data | Storage / handling |
| --- | --- |
| Parent/child names, birth date, gender and usual wake/bed times | Encrypted private vault |
| Profile photo | Decoded and rendered to a bounded image to remove imported metadata; PNG bytes in the encrypted vault |
| Sleep, wake and awake-break records | Encrypted private vault, preserving existing record formats and observation semantics |
| Observation provenance, creation ledger, unfinished operations and bounded recovery archives | Same encrypted vault; private recovery copies are included in deletion |
| Personalized AI text, source fingerprints and generation timestamps | Same encrypted vault; removed on permission withdrawal or complete local deletion |
| Cloud-sharing permission receipt | Versioned receipt in the encrypted vault; a separate non-sensitive defaults switch must also permit sharing |
| Encryption key | Keychain generic-password item, 256-bit random key, `WhenUnlocked`, not synchronizable |
| Appearance, ordinary feature preferences and routing flags | UserDefaults; routing flags alone cannot open an absent/deleted profile |
| Passwords, Apple/Google account credentials | Not collected by the current local-profile flow |
| Provider credential | No bundle/Info.plist/source/defaults credential path; Debug-only launching-process environment for development; production provider calls disabled |

`PrivateDataStore` is the dependency used by persistence and calculations.
Its UserDefaults conformance exists only in the XCTest target. Production
personal data goes through `SecureDataStore`; `SecureStorage` supplies reactive
SwiftUI bindings without another persistent plaintext copy.

## Encryption and availability

`SecureDataStore` serializes its property-list payload in memory, then uses
CryptoKit AES-GCM with a fresh random nonce and authenticated schema/vault
context. Only the version header and ciphertext reach Application Support.
There is no plaintext temporary-file or UserDefaults fallback. The vault file
is replaced atomically. Its directory and every iOS replacement use complete
file protection.

The current implementation has one foreground writer per app container.
The existing observation lock, revision checks and recovery rules remain in
place; the storage layer adds atomic encrypted replacements underneath them.
This is not a cross-process or multi-device synchronization mechanism.

Only an absent Keychain item permits key creation, and never when ciphertext
already requires the missing old key. Locked keys, corrupt ciphertext, wrong
keys and unsupported versions make storage unavailable. They do not become an
empty history. Failed writes do not publish uncommitted values. The UI blocks
private content and mutations until protected data is available or retry
succeeds; eligibility explicitly records unreadable storage.

Background/lock handling releases retained store plaintext and clears the
orchestrator's private state. Swift does not guarantee physical memory zeroing.
A scene-level privacy cover also hides presented sheets in app-switcher
snapshots. Every storage generation invalidates old callbacks: delayed avatar
imports, bound observation operations and late AI results cannot repopulate a
newly cleared vault.

User-created records remain eligible for device backups. The non-synchronizing
`WhenUnlocked` key was chosen instead of `ThisDeviceOnly`, so the implementation
does not knowingly pair backed-up ciphertext with a non-migrating key. This
does not promise universal restore behavior: verify an encrypted backup/restore
on Apple hardware before release. No cloud sync is implemented.

## Demo reset and deletion

On the first successful secure-store initialization, a scoped list of old
personal-data defaults is removed, including legacy record stores and recovery
archives. Ordinary preferences are retained. The reset marker prevents repeat
cleanup, and a missing marker cannot erase a newly created secure profile.
Failed secure initialization does not mark the reset complete.

Settings offers a confirmed **Delete All Local Data** action. It immediately
disables sharing, cancels pending private work, deletes the vault and key, and
creates an empty vault with a fresh key. The encrypted profile-setup marker is
removed along with the data. Legacy routing flags cannot reopen the profile.
Failures are shown, rather than reported as successful deletion. Local deletion
does not recall information already sent to a provider or remove old system
backups.

## Honest local setup

The previous email/password and social-login screens did not authenticate with
a server. The current flow therefore creates a **local profile**, without
collecting credentials or showing fake provider sign-in buttons. The encrypted
`profileSetupComplete_v1` marker controls setup routing; it is not a remote
authentication token. The existing internal `AuthState` naming is retained to
avoid unrelated routing refactoring.

If remote accounts are introduced later, implement real server/provider
authentication, authorization and account deletion. Store the resulting user
tokens in Keychain with an explicit lifetime policy; do not revive the former
client-only login flag as authentication.

## Cloud AI boundary

Release builds deny direct Gemini calls at compile time, even when a process
environment key or injected transport is supplied. Local tracking and
deterministic guidance remain available. Enabling production cloud coaching
requires a separately implemented production service/security design; do not
embed a provider secret in the distributed application.

Configured Debug development builds require explicit permission after the
Google Gemini disclosure. A pre-enabled `smartSuggestions` preference is not
permission. Both a current protected receipt and the independent sharing
switch must agree. Revocation disables the switch before protected cleanup,
so failure to delete a receipt cannot re-enable sharing on relaunch.

Requests and results are bound to the exact permission receipt and storage
generation. Revoking and granting permission again cannot authorize an old
in-flight result. Final cache commit/publication is serialized with revocation;
permission notifications are posted outside the privacy lock.

Prompts omit names, exact birth dates, gender, photos, account fields and
arbitrary free-text context. They use age in months, necessary sleep summaries,
predictions and structured data-quality information; day labels are relative.
This data remains personal even after removing direct identifiers. No request,
response or provider-error content is logged. The PR #34 integration preserves
its incomplete-evidence and stale-session restrictions.

The in-app **How Your Data Is Used** sheet describes actual behavior. It is not
a substitute for a published privacy policy or App Store Connect disclosures.
The existing UserDefaults required-reason manifest remains applicable to the
remaining ordinary preferences. Reassess collection declarations when the
production AI/backend design is established.

## Validation evidence

The initial reviewed patch added 62 test methods and removed none. After
applying it to merged main `4e7595a`, the portable suite was rerun on Swift
6.0.3/Linux. Native CI follow-up results and remaining checks are recorded below.

| Check | Result |
| --- | --- |
| Merged-main portable domain/storage/consent suite, before native CI follow-ups | 647 passed, 0 failed, 0 skipped |
| CI routing, selection and validation-supervisor tests | 23 Python and 3 Node tests passed; rerun |
| Supplemental orchestration/prediction/privacy suite | Prior 104 passes; source equivalence checked on initial application, not rerun |
| Cloud privacy/transport, Release configuration | Prior 18 passes; source equivalence checked on initial application, not rerun |
| Swift syntax parsing and Xcode/plist structure checks | Passed; these are not an iOS compilation |

The supplemental evidence was recovered from the reviewed package. At initial
application, all 38 direct production/test inputs and the extracted
generation-coalescer code matched the prior integration tree. Frozen service
hashes also matched; the only
transport-test difference from its earlier frozen hash is an extra trailing
newline that was removed. The final PR #34 caption/UI-test fixes do not alter
this supplemental test scope.

The existing portable runner copies domain code verbatim and explicitly
excludes its one SwiftUI-only routing test. Supplemental orchestration tests
preserve production orchestration, storage, consent, parsing and cancellation
logic, but use storage-only ObservableObject/Published stand-ins, Swift Crypto
and a Google SDK transport stub. Linux XCTest lifecycle signatures are adapted
only in the scratch harness. Counts across these runs overlap and must not be
added together as a unique-test total.

Native iOS compilation and tests have now run in GitHub Actions; this workspace
itself remains Linux. The latest completed compact run passed 939 of 940 unit
test methods, including the real Keychain test. The remaining failure was the
missing Simulator file-protection metadata described below. All 43 UI tests
encountered an app-startup crash. The root-view routing filter and same-window
privacy cover, startup preflight, and revised file-protection tests still
require native validation.
`PrivacyUITests` cover deletion, legacy-route bypass and the data-handling
explanation. Physical-device metadata/lock-unlock checks, app-switcher privacy
and encrypted backup restoration remain unverified release checks. Prior
portable results do not replace native validation of these follow-up changes.

### File-protection test boundary

The iOS 18.5 Simulator run returned no `protectionKey` metadata after a protected
write. This is not treated as proof of protection. Apple documents that this
attribute's value is an NSString, and its Simulator guidance requires physical
devices for hardware-specific features. Apple's upstream WebKit tests also
exclude Simulator when checking `NSFileProtectionKey` semantics.

`testEveryAtomicReplacementRequestsCompleteProtection` runs on Simulator and
devices: it forwards real filesystem operations while checking Complete
directory-creation/update attributes, the exact atomic + complete-protection
write options on every replacement, and the resulting file contents.
`testEveryAtomicReplacementKeepsCompleteFileProtectionOnDevice` reports an
explicit skip on Simulator. On physical devices it still requires non-nil,
Complete protection metadata for both the file and directory after every
replacement. The real Keychain test remains active on Simulator and devices.
Passing the Simulator contract test does not establish hardware enforcement;
physical-device metadata and lock/unlock validation remain release checks.

Before merging the security change, run the full configured iOS CI and CodeQL
on the final branch based on the merged PR #34. The three GitHub alerts can be
considered resolved only after the relevant analysis confirms the fix; a green
portable suite alone does not close them.

## Primary references

- [Apple: UserDefaults](https://developer.apple.com/documentation/foundation/userdefaults)
- [Apple: AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm)
- [Apple: Encrypting your app's files](https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files)
- [Apple: FileAttributeKey.protectionKey value contract](https://developer.apple.com/documentation/foundation/fileattributekey/protectionkey)
- [Apple: Simulated and physical device testing](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)
- [Apple/WebKit: FileSystem tests, makeSafeToUseMemoryMapForPath](https://github.com/WebKit/WebKit/blob/main/Tools/TestWebKitAPI/Tests/WTF/FileSystem.cpp)
- [Apple: Restricting Keychain item accessibility](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility)
- [Apple: Optimizing app data for iCloud Backup](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup)
- [Apple: App Review Guidelines, privacy](https://developer.apple.com/app-store/review/guidelines/#privacy)
- [Apple: Third-party AI sharing clarification](https://developer.apple.com/news/?id=ey6d8onl)
- [CodeQL: Cleartext preferences storage](https://codeql.github.com/codeql-query-help/swift/swift-cleartext-storage-preferences/)
