# GPU, voice and LLM notes

Known rough edges around the NVIDIA cards and the Whisper/Piper/Ollama stack. Back to the [README](../README.md).

- **`nvidia.runtime` and the container GPU library gap.** Frigate's `onnx`
  detector (and Ollama, and Whisper) initially failed with "CUDA driver
  version is insufficient for CUDA runtime version" even on a freshly
  updated host driver - misleading, since the host driver was fine. Root
  cause: Incus's plain `gpu` device only passes through the `/dev/nvidia*`
  device nodes, not the host driver's userspace libraries (`libcuda.so`
  etc) - unlike Docker's `--gpus` flag, which injects both. Fix: install
  `nvidia-container-toolkit`/`libnvidia-container` on the host (the
  `incus-host` role does this) and set `nvidia.runtime = true` on the GPU
  profiles (also automated - see `gpu-1070`/`gpu-1650` profile tasks).
  Needs driver >=570 for CUDA 12.8 (Frigate's `onnx` detector requirement);
  the earlier belief that this made Pascal (GTX 10-series) a hard dead end
  was wrong - Pascal supports driver 580 fine, confirmed working via
  NVIDIA's official `.run` installer (Debian 13's own apt repo was just
  behind at the time). Frigate's native `tensorrt` detector is still a dead
  end on x86_64 (deprecated for Jetson-only ARM builds) - use `onnx`.
  **Gotcha:** setting `nvidia.runtime` on a profile doesn't retroactively
  fix an already-running container - it needs a restart (`incus restart
  <name>`) to actually get the injected libraries.

- **Whisper defaults to CPU even with a working GPU passthrough.** The
  `rhasspy/wyoming-whisper` image's `docker_run.sh` only requests
  `--device cuda` if `STT_DEVICE=cuda` is set (same env var its own GPU
  build variant sets internally) - otherwise it silently runs on CPU with
  no error. `whisper-piper.tf` sets `"environment.STT_DEVICE" = "cuda"` to
  opt in; still needs the `nvidia.runtime` fix above and a restart to take
  effect. Piper doesn't have a GPU path at all regardless of profile - it's
  a CPU-native TTS engine by design.

- **GPU device syntax** (`incus profile device add ... gpu pci=<addr>`) is
  correct for Incus's GPU device type but pins the whole card to whichever
  container profile uses it - anything sharing a profile gets concurrent
  access to the same card. Frigate and Ollama both share `gpu-1070` now and
  fit comfortably (Frigate's detector ~250MB, Ollama's 7B Q4 model
  ~4.4-5.2GB depending on context length, well under the 1070's 8GB) - keep
  an eye on `nvidia-smi` if you add a third consumer or a bigger model.
  Ollama itself will only keep one model resident on a GPU at a time by
  default (no `OLLAMA_MAX_LOADED_MODELS` override here) - loading a second
  model that doesn't fit alongside the first evicts it entirely rather than
  splitting across GPU/CPU, so don't expect two large models warm at once
  on one card.
  **Ollama can silently end up on CPU after a host reboot.** It probes for
  GPUs once, at startup, with a hard 30s watchdog per backend (CUDA 12,
  CUDA 13, Vulkan) and no env var to extend it. On a cold boot the host is
  swamped starting the HAOS/UniFi VMs (Incus itself took ~190s to finish
  starting; load average >10 for 10+ minutes), discovery times out
  (`llama-server GPU discovery watchdog timed out` in the container's
  console log), Ollama logs `inference compute id=cpu`, and HA's "keep
  loaded forever" setting then pins the CPU-resident model indefinitely
  (seen twice: `qwen2.5:7b` at "100% CPU", 1070 idle, Assist never
  answering - no error anywhere, just high host CPU). **Ordering Incus after
  the NVIDIA units did not fix this** (tried first; the driver was already
  up - it's contention, not readiness). What does: the `incus-host` role
  installs `ollama-gpu-check.timer` (4 min after boot, then every 5 min),
  which restarts the `ollama` container if its startup log says
  `id=cpu` or a loaded model has no VRAM - capped at 3 restarts per boot so
  a genuinely broken GPU can't flap it forever (logs to the journal:
  `journalctl -u ollama-gpu-check`). After a self-heal restart nothing is
  preloaded, so the first Assist query pays a ~35s model load.
  Side fix from the same investigation: Debian ships the `nvidia-persistenced`
  binary but no unit, so the old enable task silently did nothing and
  `nvidia-power-limits.service` (which `Requires=` it) never ran at boot;
  the role now installs the unit, and `incus`/`incus-startup` wait for both.

- **Ollama's model and HA wiring aren't managed by this repo** (same
  reasoning as [Frigate's camera config](services.md) - it's runtime/data-plane
  state, not infrastructure). Currently running `qwen2.5:7b` as a single
  model for both HA's Assist conversation agent and general coding use (e.g.
  a VSCode extension pointed at `http://<host-ip>:11434` directly, bypassing
  HA entirely) rather than juggling two models that don't both fit in 8GB
  VRAM at once. Wired into HA via Settings > Devices & Services > Ollama
  (`http://<host-ip>:11434`), then its "conversation" subentry picks the
  model, context length (`num_ctx` - each doubling costs real VRAM, roughly
  4.4GB/4.8GB/5.2GB at 4096/8192/16384 tokens for this model), and which LLM
  APIs it gets (`assist` for device control, `llm_intents` for search tools -
  see below). Assigned as the conversation engine on the Assist pipeline
  that also uses Whisper/Piper.
  **A model listing `tools` as a capability doesn't mean it reliably
  produces tool calls Ollama can actually parse.** `qwen2.5-coder:7b` was
  tried first (reasoning: Qwen's coder fine-tunes are marketed as retaining
  general ability, so one model could cover both HA tool-calling and VSCode
  coding) - it silently failed every time: instead of wrapping its function
  call in the `<tool_call>` tags its own chat template requires, it printed
  the raw `{"name": ..., "arguments": ...}` JSON as plain assistant text,
  which Ollama can't parse into a real tool call - no error, it just looks
  like an oddly-formatted normal reply. Plain `qwen2.5:7b` and `llama3.1:8b`
  both passed a repeated direct test against Ollama's `/api/chat` (structured
  `tool_calls` field present, 3/3 tries) - `qwen2.5:7b` was kept since it
  uses less VRAM at the same context length. If you change models, verify
  tool-calling with a direct `/api/chat` call and a dummy `tools` array
  before trusting it in HA - the failure mode is silent, not an error.

- **Web search / Wikipedia tools for Ollama**: HA core has no built-in way
  for a conversation agent to search the web - this needs the HACS custom
  integration `skye-harris/llm_intents` ("Tools for Assist") - not part of
  this repo's prerequisites, install it yourself via HACS: search "Tools for
  Assist" > install > restart HA. It registers an
  additional LLM API (`llm_intents`, shown as "Search Services" in the
  conversation agent's API selector) alongside HA's own `assist` API, and
  its search provider is self-hosted **SearXNG** (`terraform/searxng.tf`,
  `docker:searxng/searxng` image) rather than the integration's other option
  (Brave Search API - free tier, but needs a signup/key) since SearXNG needs
  neither an API key nor a per-query cost. SearXNG's default `settings.yml`
  disables its JSON API (`search.formats: [html]` only, to deter scraping on
  public instances) - not templated here since a hand-authored settings.yml
  risks missing keys the image expects; let the image generate its own
  default on first boot (`/var/incus-volumes/searxng/config/settings.yml`),
  then add `json` to `search.formats` by hand and restart the container.
  **Wikipedia's tool was broken, then patched locally - this patch WILL be
  silently erased by a future HACS update, until the upstream fix ships.**
  `llm_intents` called Wikipedia's API through HA's shared `aiohttp` client
  session without setting a custom `User-Agent` - Wikipedia rejects that
  default signature outright per its own [API etiquette
  policy](https://meta.wikimedia.org/wiki/User-Agent_policy) (confirmed:
  the exact same request 403s with HA's default UA string and 200s with
  any descriptive one), so the tool failed every time, and the model was
  observed silently falling back to stale training-data answers instead of
  reporting the failure (asked "who is the current pope" mid-2026, got the
  previous one back with no hint anything had gone wrong).
  Fixed by patching the installed
  `/config/custom_components/llm_intents/wikipedia.py` directly (added a
  `User-Agent` header to its two `session.get()` calls, via SSH to HAOS's
  Terminal & SSH add-on) and re-enabling Wikipedia in the integration
  options - confirmed working with real, current Wikipedia content. Also
  submitted upstream as
  [skye-harris/llm_intents#165](https://github.com/skye-harris/llm_intents/pull/165)
  so this isn't just a local patch waiting to be erased.
  **This is exactly the kind of fix that doesn't survive a HACS update** -
  HACS will pull a fresh copy of `wikipedia.py` from GitHub on the next
  update to this integration, silently reverting the patch (no error, it'll
  just start failing again with the same symptom: model answers as if the
  lookup never happened). Until PR #165 (or an equivalent) is merged and
  released: after any `llm_intents` update, check whether Wikipedia answers
  are actually current, and if not, check the PR's status - if unmerged,
  reapply the same two-line header change by hand.
