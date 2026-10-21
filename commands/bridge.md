---
description: Set up cloud sessions on this Mac (the bridge, a tunnel from any provider, the values for claude.ai), check them, or remove them
argument-hint: "[check|new-keys|remove]"
---

Cloud sessions reach this Mac through the bridge (`bridge-server.py`, on 127.0.0.1:8765 only) and a tunnel that gives it a public address. Any tunnel provider works. `install-bridge.sh` does the Mac's part; the Handfree Code app (Settings > Cloud sessions) runs the same script.

Run every command outside the sandbox. The script is `"${CLAUDE_PLUGIN_ROOT}/bin/install-bridge.sh"`.

**Never write a key in the conversation** (`bridge_token`, `bridge_edge_key`, a provider's token): the user copies them from the app, which asks for Touch ID or their password first.

## With an argument

- `check`: run the script with `--check` and tell the user its verdict in a sentence.
- `new-keys`: ask first (cloud sessions stay silent until the new keys are given to claude.ai and to the provider's rule), then run it with `--new-keys`, then say where the new keys go (the end of this page).
- `remove`: run it with `--uninstall`. The keys stay in `~/.config/handfree-code.json`; the tunnel itself, at the provider, stays too.

## Without an argument: the whole setup

1. **The bridge.** Run the script. It makes the two keys if missing and starts the bridge with the user's session.
2. **The tunnel.** Read `~/.config/handfree-code.json`: with a `bridge_url` already, run the script with `--check`; if it passes, skip to step 4. Otherwise ask the user which provider they use or want (with the voice mode's dictation tool when voice mode is on):
   - **Cloudflare** (needs a domain managed by Cloudflare): `cloudflared` installed (`brew install cloudflared`, after asking), then `cloudflared tunnel login` (a browser page: the user picks the domain), `cloudflared tunnel create handfree`, `cloudflared tunnel route dns handfree <hostname>` with the hostname the user chooses on that domain. Write `~/.cloudflared/config.yml` (ask before replacing one):
     ```yaml
     tunnel: handfree
     credentials-file: <home>/.cloudflared/<the tunnel's id>.json
     ingress:
       - hostname: <hostname>
         service: http://localhost:8765
       - service: http_status:404
     ```
     The address is `https://<hostname>`, the command `cloudflared tunnel run handfree`.
   - **ngrok**: the user adds their token themselves (`ngrok config add-authtoken …`) and reserves a fixed domain in ngrok's dashboard. The command is `ngrok http --url=<domain> 8765`, the address `https://<domain>`.
   - **Tailscale Funnel**: `tailscale funnel --bg 8765` once (Tailscale's own service then carries it); the address is the one it prints (`https://<machine>.<tailnet>.ts.net`). No command.
   - **Another provider**: its address must stay the same from one start to the next; ask for its command, if it has one to keep running.

   When the provider already runs the tunnel by its own service, leave the command empty. A service of the provider's that runs without a tunnel of its own configured carries nothing: then set the command.
3. **Save and start.** Write `bridge_url` and `tunnel_command` (omitted when empty) into `~/.config/handfree-code.json`, keeping every other key, then run the script again: it starts the tunnel's service. Run it with `--check` and act on the verdict: unreachable, see the tunnel's log (`~/Library/Logs/handfree-tunnel.log`); refused by the provider, see step 4's rule; not this bridge, the tunnel does not point at `http://localhost:8765`.
4. **The provider's rule** (when it can filter requests before they reach the Mac; recommended): it lets through only requests carrying the header `X-Handfree-Key` with the edge key. For Cloudflare: dashboard > the domain > Security > WAF > Custom rules, in this order:
   1. action *Block*: `(http.host eq "<hostname>" and not any(http.request.headers["x-handfree-key"][*] eq "<EDGE-KEY>"))`
   2. action *Skip*, ticking all remaining custom rules, all managed rules, Super Bot Fight Mode, Browser Integrity Check and Security Level: `(http.host eq "<hostname>" and any(http.request.headers["x-handfree-key"][*] eq "<EDGE-KEY>"))`

   The user pastes the edge key in place of `<EDGE-KEY>` from the app (Cloud sessions > Copy the edge key). Then `--check` again.
5. **claude.ai.** Tell the user: in the cloud environment's settings, paste the environment variables (app: Cloud sessions > Copy the variables) and the setup script (Copy the setup script). If outbound traffic is filtered there, allow `github.com`, `raw.githubusercontent.com` and the tunnel's host. A cloud session opened after that speaks and asks through this Mac.

End with a few lines: what is running, the check's verdict, and what is left to the user.
