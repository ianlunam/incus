# Power savings

Back to the [README](../README.md).


Applied by the `incus-host` role, all tunable in `group_vars/all.yml`:
- TLP (PCIe ASPM, SATA/USB link power management) - `enable_tlp`
- CPU governor pinned to `powersave` by default - `cpu_governor`
- Both GPUs power-capped well under their stock TDP - `nvidia_1070_power_limit_w`,
  `nvidia_1650_power_limit_w` (persisted via a systemd unit, not just a
  one-shot `nvidia-smi` call that reverts on reboot)
- ZFS ARC capped at 4GiB so cache doesn't creep across all 48GB - `zfs_arc_max_bytes`

If Frigate detection latency or LLM inference feels sluggish, the GPU power
caps are the first thing to loosen - raise `nvidia_1070_power_limit_w`
toward stock (~150W) and re-run the playbook.
