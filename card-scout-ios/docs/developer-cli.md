# Developer CLI

From `card-scout-ios/`:

```sh
python3 mac/dev.py quota
python3 mac/dev.py quota --refresh
python3 mac/dev.py health
python3 mac/dev.py queue
python3 mac/dev.py doctor
```

`quota` reads the worker's shared usage ledger without a provider call.
`quota --refresh` checks CardSight's account-wide usage. The existing one-hour
subscription cache and quota protections apply. A fresh check reserves one
request; failed calls remain counted. API keys never enter the report.

Remaining quota is conservative usage subtracted from the configured app cap,
not an allowance fetched from CardSight. The current source cap is 5,000. Unknown
or stale provider usage stays unknown. A reached app cap reports zero without
calling the provider. Neither this command nor any other command buys calls,
changes limits, retries errors, or removes account pauses.

`health` checks authenticated HTTPS `/v1/ping`, verifies the worker certificate
and hostname, and refuses redirects. `queue` opens SQLite in read-only mode and
reports aggregate counts; it never starts, retries, cancels or edits jobs. Saved
card identities, analyses, photos and tokens are omitted. `doctor` combines health,
queue and local quota checks. It never contacts CardSight.

## Use the existing VPS from the Mac

```sh
python3 mac/dev.py --ssh admin@worker.example doctor
python3 mac/dev.py --ssh admin@worker.example quota --refresh
python3 mac/dev.py --ssh admin@worker.example --json queue
```

SSH uses existing authentication and strict known-host verification. The CLI
streams its own source to Python on the server and runs as the existing
`cardscout` user. It imports the installed worker modules from
`/opt/cardscout/service`; no CLI deployment, service restart, new app endpoint, or
iPhone install is needed. No Mac credentials or runtime files are copied. The
SSH account must be able to run `sudo -n -u cardscout`.

## Local worker and scripting

The default data directory is `~/Library/Application Support/CardScoutMac` on
macOS and `/var/lib/cardscout/data` on Linux. Remote checks default to the Linux
path. Use `--data` for an explicit directory. The directory must already exist.

```sh
python3 mac/dev.py --data '/path/to/worker data' --json quota
python3 mac/dev.py --data '/path/to/worker data' --json doctor
```

Global options (`--data`, `--ssh`, `--json`) go before the command. Only `quota`
accepts `--refresh`. Exit 0 means the requested checks could be read; it does not
mean quota is available. Inspect quota `status` and `remaining` for availability.
Exit 1 means at least one check could not complete. Invalid arguments exit 2.
Unknown remaining quota is JSON `null`. Errors are generic and omit exception
messages and raw provider/SSH responses.

All commands leave collections and jobs unchanged. A free quota read can create
or touch the existing budget lock file. Only an explicit refresh can update the
usage ledger and spend a provider request. App source no longer contains the
quota screen, app state, localization keys or quota HTTP endpoint from the
initial implementation.

## Verification — 17 November 2026

313 worker tests and 198 Swift tests passed (one existing Swift skip). The
localization audit and simulator app build passed after removing the app quota
feature. CLI tests cover read-only queue access, missing directories, safe errors,
verified authenticated HTTPS, blocked/unknown quota, provider-failure redaction,
month rollover, shared caching and quoted SSH paths.

The streamed CLI also passed a live SSH `doctor` check against the existing VPS:
authenticated TLS health was healthy, the queue had no active jobs, and the shared
ledger reported 836/5,000 used with 4,164 remaining. This used the existing provider
check and spent no CardSight request. These numbers are a dated snapshot; rerun
the CLI for current state. No app installation or worker restart was needed.
