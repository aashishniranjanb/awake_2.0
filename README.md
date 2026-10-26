# AWAKE 2.0 — AgriSense-IPMS digital RTL

Synthesizable Verilog-2005 RTL for an event-driven agricultural sensor-processing core. It includes per-sensor EMA crossover detection (DECDE), direction-aware temporal fusion, a weighted crop-stress accelerator (CSA), a 7-node decision tree, a stress-aware ADC resolution policy (SA-ADC), and a 4-state power-manager FSM (IPM) behind a register bus.

## Scope

| Implemented and verified | Not implemented (interfaces only / out of scope) |
|---|---|
| `rtl/common` sync, sample pipeline, register file, isolation | Sensor Interface Engine (sensors enter as parallel 8-bit pins) |
| `rtl/decde` EMA, crossover, fusion | LoRa / packet formatting (`comm_en_out` and `domain3_pwr_en` are outputs only) |
| `rtl/csa` weighted sum + normalization | History SRAM |
| `rtl/dt` decision tree | Analog ADC (SA-ADC outputs the *requested* mode vector only) |
| `rtl/sa_adc` mode policy | Physical power gating / UPF (power enables and isolation are logical) |
| `rtl/ipm` FSM, wake sync, isolation | |

Sensor contract: `sample_valid` is synchronised by 2 flip-flops and the 48-bit sensor bundle is delayed by the same 2 stages, so sensor data must be held stable for at least 3 clock cycles around a `sample_valid` cycle. Each cycle where `sample_valid` is high while `sensor_en` is set (MONITOR or above) accepts one sample.

The CSA is serialized: one shared multiplier, with the stress score valid 5 clock edges after the sample is accepted. See `docs/CSA_CHECKLIST.md`.

Specifications are in `docs/`. The register contract and reset defaults are in `docs/register_map.md`.

## Verify (Linux / Codespace, or Windows Git-Bash with oss-cad-suite on PATH)

```bash
bash scripts/regress_iverilog.sh   # 13 self-checking benches; each must print "TEST PASSED <name>"
bash scripts/lint.sh               # Verilator -Wall, zero warnings
bash scripts/synth.sh              # Yosys generic synthesis; fails on latches, multiple drivers, undriven nets
```

Outputs go to `build/` (git-ignored). Generic Yosys cell counts are not SKY130 area or timing.

## Physical design input

`flow/config.json` is an OpenLane 2 / LibreLane configuration for SKY130 (`sky130_fd_sc_hd`). It is an input only. No physical results are published in this repository.

**The `CLOCK_PERIOD` of 20 ns is provisional.** It is a placeholder, not a requirement. The intended operating frequency has not been established, so do not treat timing results at 20 ns as meeting a specification.

## Open design issues (behaviour intentionally unchanged)

1. **Shared stress code.** `HIGH_STRESS` and `CRITICAL_STRESS` both encode as `4'b1100`, so the two leaves are indistinguishable. `docs/DECISION_TREE_SPEC.md` lists 3-bit codes; an encoding decision is needed.
2. **Unreachable vote thresholds.** `VOTE_THRESHOLD` values 6 and 7 can never fire with 5 channels. Decide whether to saturate, reject, or document them as "disabled".
3. **No sleep re-entry.** There is no MONITOR→SLEEP transition; after the first wake the chip stays at MONITOR or above until reset. A return-to-sleep condition (timer, idle count, or host command) is unspecified.
4. **ADC threshold defaults.** The SA-ADC thresholds reset to 0, so every channel requests 12-bit mode until the host programs them. Decide whether the reset default should be low-power (8-bit) instead.

`sim/traces/*.csv` are synthetic workload traces; `sim/scripts/generate_traces.py` regenerates them.
