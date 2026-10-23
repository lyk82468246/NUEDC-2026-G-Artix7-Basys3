# 2026-10-24 measurement-debug verification

Scope: RTL/source registration/host decoding only. No synthesis, implementation,
IP regeneration, bit generation, FPGA programming, reset or instrument access.

| Command | Result |
| --- | --- |
| run_measurement_debug_sim.ps1 | PASS snapshot assertions and VIO on/off top port contract |
| run_runtime_calibration_sim.ps1 | PASS atomic banks, epochs, invalid, rounding, saturation |
| run_contest_sim.ps1 | PASS all nine controller/AFE/component/HMI test runs |
| run_behavioral_sim.ps1 | PASS time statistics, real FFT/CORDIC models, peak scan, UART/HMI |
| Python instruments unittest discovery | PASS 105 tests |

Snapshot assertions cover full unsigned widths, slot masking/count 0..3, invalid
signal, reset, stable hold, frame-ID wrap, disabled VIO, and sample/update collision.
Top contract uses simulation-only ILA ports and black-box DSP/VIO/MMCM ports; it
does not verify vendor ILA storage. Never add sim/ila_system_debug_contract.sv to
the synthesis fileset.

FFT PASS: 8192 input reads, 4096 frequency writes; legal input backpressure counted
8192 times, output backpressure 0. TVALID/payload/TLAST stability assertions pass.
Simulation completed at 555250 ns; host model runtime ~5m13s, unrelated to board
latency. Peak scan PASS: 3991 bins, selected123 =>61500Hz, amplitude10000. UART
PASS:184 decoded bytes. Time statistics PASS:8192 BRAM reads, Vpp16000,
mean_square23992065, Vrms4898 (raw test-vector units).

Old bit is untouched (2026-10-23 22:46:24). Existing ILA generated products still
have ten probes. User must run setup_measurement_debug.tcl in the correct open
GUI project, then manually build/verify/program a NEW matching bit/LTX pair.
FIR equalizer and existing VIO enable parameter remain unchanged.
