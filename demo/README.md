# Demo recordings

The GIFs in the main README are real recordings of the released Homebrew build against a live Cloudflare domain. Nothing is mocked.

| File | Story | Reproduce |
|---|---|---|
| `setup.gif` | Install from the tap, then `share setup`: tunnel, DNS record, login service, live check | `demo/render.sh setup` |
| `use.gif` | Share a folder, fetch it like a visitor, show that `.env` stays private, count hits, take it down | `demo/render.sh use` |
| `visitor.png` | What a visitor sees: the folder's `README.md` rendered to HTML, image and links intact | headless Chromium screenshot of the shared link |

## Re-record

Needs vhs, ffmpeg, a domain on Cloudflare, and `CLOUDFLARE_API_TOKEN` in the environment (without it, setup opens the browser login mid-recording). The tapes use the hostname `share-demo.han.ws`; change it to one of yours.

```sh
brew uninstall share 2>/dev/null     # so setup.gif shows a fresh install
demo/render.sh setup
demo/render.sh use
source demo/env.sh && share teardown --yes   # remove the demo tunnel, DNS record, and service
```

`demo/env.sh` is the hidden prelude of every tape. It gives the demo its own config, root, port, and service label, so a recording never touches a real share setup on the same machine.

`render.sh` lets vhs capture the frames and builds the GIF with ffmpeg itself, because vhs's own encoder step fails silently with ffmpeg 9. The theme is One Dark and the font is Lilex.
