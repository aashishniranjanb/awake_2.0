# CSA Verification Checklist

Add these test cases to catch arithmetic bugs in the CSA verification suite:

- [ ] **Test A**: `csa_en = 0`
  - Expected: `stress_score = 0`
- [ ] **Test B**: all sensors = 255, all weights = 255
  - Expected: No overflow, No X values
- [ ] **Test C**: Only moisture active
  - Verify: `stress_score` changes
- [ ] **Test D**: Only light active
  - Verify: `stress_score` changes
- [ ] **Test E**: All weights = 0
  - Expected: `stress_score = 0`

## Serialized CSA contract (branch `opt/csa-serial`)
- One shared 8x8 multiplier; lanes 0..4 = moisture, leaf_temp, humidity, air_temp, light.
- Edge S = the edge at which a start is sampled. Edges S+1..S+5 accumulate lanes 0..4. Edge S+5 loads `stress_score` and sets `score_valid`. **Latency = 5 edges** from start; the start edge is the sample-acceptance edge, so the score is valid 5 edges after acceptance (the parallel CSA needed 1).
- Start = new accepted sample, or Domain 2 on with a held sample and no valid score. Operands are the held tuple `sampled_*` and live weights/shift.
- A weight or shift write (0x10–0x14, 0x19) while busy restarts at lane 0. The same applies to a write on the same edge as a start, so every result uses post-write configuration. A restart on the final edge wins over completion. An idle write does not recompute.
- A new sample while busy restarts with the newer sample. `enable = 0` aborts and clears `score_valid`. `stress_score` holds its last completed value.
- 19-bit accumulator: 5 x 255 x 255 = 325,125 < 2^19.
- The DT/IPM use the score only when `leaf_valid = dtree_en & csa_score_valid`, so the WARNING/CRITICAL decision follows 4 cycles later than with the parallel CSA.
- Checked by `tb/tb_csa.v`: exact latency, holds, restarts, abort, limits, lane isolation, and 2,000 random vectors against `min(255, sum(s*w) >> shift)`.
