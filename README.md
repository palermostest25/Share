# Share

Share is a private, streaming network drive for two people. Files remain on the TrueNAS dataset. The native Mac app and built-in web UI browse the server live; neither syncs the drive to the Mac.

## TrueNAS setup

1. Create the dataset `/mnt/Tank/Share` and grant UID/GID `568:568` read, write, and modify access.
2. Copy `Share-server-1.1.0-linux-amd64.tar` to TrueNAS and run `docker load -i Share-server-1.1.0-linux-amd64.tar` from the TrueNAS shell. It loads both `share-server:latest` and `share-server:1.1.0`; Compose uses `latest`.
3. Generate the shared key with `openssl rand -base64 48` and save it in a password manager.
4. Keep your Cloudflare container separate. Point its `share.denby.dev` public hostname at `http://<TrueNAS-LAN-IP>:8080`.
5. Open `deploy/compose.yaml`, replace the `ACCESS_KEY` placeholder, and install it in TrueNAS Apps using **Install via YAML**. No router port forward is required.
6. Add a Cloudflare cache rule for hostname `share.denby.dev` with **Cache eligibility: Bypass cache**. Enable Always Use HTTPS and minimum TLS 1.2.
7. Create periodic ZFS snapshots on `Tank/Share`: hourly retained for 48 hours and daily retained for 30 days.

The web UI is available at `http://<TrueNAS-LAN-IP>:8080` on your LAN and `https://share.denby.dev` remotely. Its key is held in the current browser tab’s session storage; the browser may persist session state, so use **Lock** on a shared computer. Favourites stay in that browser. The Mac app stores the key in Keychain and uses the optional Local URL when it can reach it.

In the Mac app, choose **Show in Finder** to mount the same files as a network volume (normally `/Volumes/Share`). Finder can browse, create folders, move, rename, delete, and open files. If the volume does not appear in Finder’s sidebar, enable **Connected servers** in Finder Settings > Sidebar; the app also opens the mounted volume directly. Finder and Preview control their own caching, so open large videos in the Share app or web player when you must avoid a complete local copy. Those players use byte-range streaming. Non-media files opened in the app are downloaded temporarily; files over 2 GB require confirmation.

Finder uses the WebDAV URL `/Share/` with username `share` and the same access key as its password. The Mac app mounts the local URL first when available, then the HTTPS remote URL. Finder cannot attach Cloudflare Access service-token headers. If you use Cloudflare Access, mount on LAN or create an appropriate exception for `/Share/`. Large Finder uploads through Cloudflare may hit your Cloudflare plan’s request-size limit; the Share app and web UI use 32 MB upload chunks.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `ACCESS_KEY` | required | Shared secret, at least 32 characters |
| `DATA_DIR` | `/data` | Shared folder inside the container |
| `LISTEN_ADDR` | `:8080` | Internal listen address |
| `CHUNK_SIZE` | `33554432` | Resumable upload chunk size |
| `LINK_TTL` | `12h` | Signed media-link lifetime |
| `UPLOAD_TTL` | `24h` | Abandoned-upload lifetime |

Rotate the key by replacing `ACCESS_KEY` in the TrueNAS YAML and redeploying. Paste the new key into both Macs. Rotation immediately invalidates old streaming links.

To restore a deleted or replaced file, clone the appropriate ZFS snapshot or copy the file from the snapshot into the live dataset. Avoid rolling back the whole dataset unless every newer change should also be discarded.

## Development checks

Run `go test -race ./...` in `server/`. The server uses the Go standard library and `golang.org/x/net/webdav`; the Mac app uses Apple frameworks.
