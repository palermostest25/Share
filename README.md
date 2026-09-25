# Share

Share is a self-hosted file manager for a TrueNAS dataset. It has a browser UI, a native macOS app, and Windows/Linux desktop packages. It does not sync the drive to the computer. Large video and audio files play through byte-range streaming, so playback and seeking do not first cache the whole file locally.

## Run on TrueNAS

1. Create `/mnt/Tank/Share` and give UID/GID `568:568` read/write access.
2. Use [`deploy/compose.yaml`](deploy/compose.yaml) as the TrueNAS Custom App YAML. Replace the `ACCESS_KEY` placeholder with a random bootstrap secret (`openssl rand -hex 32`). The only service is `share`; keep your Cloudflare tunnel in its own container.
3. The service publishes `8080` on the LAN. Point `share.denby.dev` in your separate Cloudflare tunnel at `http://<TrueNAS-LAN-IP>:8080`. Configure Cloudflare to bypass caching for this hostname and enforce HTTPS for remote access.
4. Open `https://share.denby.dev`, or `http://<TrueNAS-LAN-IP>:8080` on a trusted LAN. The first visit asks for the bootstrap key, a username, and your own password. That account becomes admin. Further accounts start with **no file access** until the admin shares a file or folder.
5. Enable ZFS snapshots. Share deletes and replaces files in the live dataset; snapshots are the recovery path.

The GHCR image is `ghcr.io/palermostest25/share:latest` (Linux amd64). On TrueNAS, updating means pulling the latest image and recreating the app. `pull_policy: always` takes effect on deployment/restart; Share deliberately does not have Docker socket access and cannot restart itself. See [TrueNAS setup](deploy/TRUENAS-SETUP.md).

## Use Share

- The web UI can browse, search within a folder, upload (including dropped folders), cancel uploads, create folders, rename, move, delete, share, and manage accounts. Right-click an item for actions. Folder rows accept dropped files or other Share items.
- Admins can grant another account read-only or read/write access to an existing file or folder. Grants are enforced by the API and WebDAV server, not only hidden in the UI. Expiring file links remain valid only while their creator still has access. Users can change their own password.
- The native Mac app browses, uploads, moves, renames, deletes, previews with Space, streams media, and mounts `/Share/` as a WebDAV volume with **Show in Finder**. Finder's sidebar must have **Connected servers** enabled in Finder Settings. WebDAV is a mounted volume, not a File Provider extension; Finder/Preview may cache files they open. For a multi-gigabyte video without a local copy, use the Share app or web player.
- Windows and Linux packages are built from [`desktop/`](desktop/) and appear on [GitHub Releases](https://github.com/palermostest25/Share/releases). The desktop shell loads the same web UI in an isolated renderer. Windows installer builds check, download, and prompt to apply GitHub Release updates. Linux checks releases and opens the new package for installation.

Local HTTP is available on private networks, but it is **not encrypted**. Use it only on a trusted LAN; use HTTPS for remote access. Finder may show an “Unsecured Connection” warning when mounting local HTTP. The Mac app prefers the HTTPS mount when reachable and uses LAN WebDAV as a fallback. Cloudflare Access service-token headers cannot be supplied by Finder; if Access is enabled, mount on LAN or configure the route accordingly.

## Updates

The web UI and Mac app check GitHub Releases automatically once a day and also have **Check updates** buttons. The Mac build here is unsigned, so macOS updates are downloaded to Downloads for manual replacement; silent self-update requires Apple signing/notarization. Linux DEB/RPM updates also need a package-manager install. Windows Squirrel builds use Electron's GitHub Release updater.

Releases are built from `v*` tags by GitHub Actions. A separate action publishes the amd64 server image to GHCR on pushes to `main` and version tags. `latest` tracks the latest successful build. Build/test checks are `go test -race ./...` in `server/`, `npm test` in `desktop/`, and an Xcode build in `mac/`.

`ACCESS_KEY` is a bootstrap secret only after the first admin is created. The old shared-key API and WebDAV access are disabled by default after setup. Set `ALLOW_LEGACY_KEY=true` only temporarily if you must migrate an old Mac client, then remove it. Rotate `ACCESS_KEY` if it was ever exposed; rotating it invalidates sessions and signed links, so users must sign in again.
