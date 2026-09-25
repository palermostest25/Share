# Install Share on TrueNAS

This package is prepared for an `amd64` TrueNAS 24.10-or-newer server and the dataset `/mnt/Tank/Share`.

1. In **Datasets**, create `Tank/Share`. Give the built-in apps user and group (`568:568`) read, write, execute, and modify access.
2. Copy `Share-server-1.1.0-linux-amd64.tar` onto the TrueNAS box. In **System Settings > Shell**, load it:

   ```sh
   docker load -i /path/to/Share-server-1.1.0-linux-amd64.tar
   ```

   The result must include `share-server:latest` (the archive also keeps `share-server:1.1.0`).

3. On the Mac, generate the shared key and save it in a password manager:

   ```sh
   openssl rand -base64 48
   ```

4. Keep your existing Cloudflare container separate. Point its `share.denby.dev` public hostname at `http://<TrueNAS-LAN-IP>:8080`.
5. In Cloudflare, add a Cache Rule matching hostname `share.denby.dev` and choose **Bypass cache**. Enable **Always Use HTTPS** and minimum TLS 1.2.
6. Open `compose.yaml` and replace the `ACCESS_KEY` placeholder with the shared key.
7. In TrueNAS **Apps**, choose **Discover Apps > Custom App > Install via YAML** (wording varies slightly by release), paste the entire Compose file, and install it.
8. Visit `http://<TrueNAS-LAN-IP>:8080` on your LAN or `https://share.denby.dev` remotely. In `Share.app`, the remote URL is prefilled; set **Local URL** to the LAN address and paste the key. Use **Show in Finder** to mount a network volume at `/Volumes/Share`.
9. Under **Data Protection**, create snapshot tasks for `Tank/Share`: hourly retained 48 hours and daily retained 30 days.

Compose publishes port 8080 on the TrueNAS LAN. The separate Cloudflare container uses that address; no router port forward is needed. The Mac app tries the local URL first and falls back to `share.denby.dev` when away. Local HTTP carries the shared key on your LAN, so use only a trusted local network. Video and audio links support HTTP byte ranges, so playback and seeking do not download the whole file to the Mac.

Version 1.1.0 adds the Finder mount endpoint. If an older `share-server` image is already imported, load this new archive and update/recreate the TrueNAS app using the `share-server:latest` Compose tag. Finder may cache opened files; use the Share app or browser player for large videos when local storage matters. Finder remote uploads may be constrained by Cloudflare request limits, while Share uploads use resumable 32 MB chunks.
