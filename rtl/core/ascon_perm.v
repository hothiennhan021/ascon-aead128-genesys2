// Sequential permutation engine: holds the 320-bit Ascon state and
// runs ROUNDS_PER_CYCLE ascon_round instances (chained purely
// combinationally, no intermediate register) per clock cycle, from
// round_start through round 15. state_i/state_o pack {S0,S1,S2,S3,S4},
// S0 in the highest bits. `load` overwrites the state register
// without running a round (used by ascon_aead_fsm to XOR data/key
// into the rate/capacity words between permutation calls).
// Asynchronous active-low reset.
//
// ROUNDS_PER_CYCLE=1 (default) is the original architecture, kept
// bit-for-bit unchanged. ROUNDS_PER_CYCLE=N (2, 4, ...) chains N
// ascon_round instances purely combinationally (no intermediate
// register): instance i takes round_idx+i, the counter steps by N
// each cycle. Requires 12 (p12) and 8 (p8) to both be exact multiples
// of N -- true for N=1,2,4 (p12: 12/N cycles starting at index 4;
// p8: 8/N cycles starting at index 8) -- so no odd-round remainder
// handling is needed (see docs/uarch.md section 6/3.1).
//
// Selected at compile time via the `ROUNDS_PER_CYCLE preprocessor
// macro (default 1 if undefined), not by a runtime parameter
// override -- pass `-DROUNDS_PER_CYCLE=2` to iverilog / `-define
// ROUNDS_PER_CYCLE=2` to Vivado's read_verilog (see Makefile,
// scripts/synth_ooc.tcl).

`ifdef ROUNDS_PER_CYCLE
    `define ROUNDS_PER_CYCLE_DEFAULT `ROUNDS_PER_CYCLE
`else
    `define ROUNDS_PER_CYCLE_DEFAULT 1
`endif

module ascon_perm #(
    parameter ROUNDS_PER_CYCLE = `ROUNDS_PER_CYCLE_DEFAULT
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [319:0] state_i,
    input  wire        load,
    input  wire        start,
    input  wire [3:0]  round_start,
    output wire        busy,
    output wire        done,
    output wire [319:0] state_o
);

    reg [319:0] state;
    reg [3:0]   round_idx;
    reg         busy_r;
    reg         done_r;

    wire [63:0] cur_x0 = state[319:256];
    wire [63:0] cur_x1 = state[255:192];
    wire [63:0] cur_x2 = state[191:128];
    wire [63:0] cur_x3 = state[127:64];
    wire [63:0] cur_x4 = state[63:0];

    wire [3:0] eff_idx = start ? round_start : round_idx;

    // last round_idx value that still needs a cycle: 15 for
    // ROUNDS_PER_CYCLE=1, 12 for ROUNDS_PER_CYCLE=4, etc. --
    // 4'd15 - (STEP-1).
    localparam [3:0] STEP          = ROUNDS_PER_CYCLE[3:0];
    localparam [3:0] LAST_ROUND_IDX = 4'd15 - (STEP - 4'd1);

    // Chain of ROUNDS_PER_CYCLE ascon_round instances: chain_x*[0] is
    // the current state, chain_x*[k] is the state after k rounds of
    // this cycle. chain_x*[ROUNDS_PER_CYCLE] is the cycle's result.
    // Array indices are all genvar/generate-time constants (no
    // runtime addressing), so this elaborates to a plain fixed chain
    // of wires, one per generate iteration -- not a memory.
    wire [63:0] chain_x0 [0:ROUNDS_PER_CYCLE];
    wire [63:0] chain_x1 [0:ROUNDS_PER_CYCLE];
    wire [63:0] chain_x2 [0:ROUNDS_PER_CYCLE];
    wire [63:0] chain_x3 [0:ROUNDS_PER_CYCLE];
    wire [63:0] chain_x4 [0:ROUNDS_PER_CYCLE];

    assign chain_x0[0] = cur_x0;
    assign chain_x1[0] = cur_x1;
    assign chain_x2[0] = cur_x2;
    assign chain_x3[0] = cur_x3;
    assign chain_x4[0] = cur_x4;

    genvar gi;
    generate
        for (gi = 0; gi < ROUNDS_PER_CYCLE; gi = gi + 1) begin : g_rounds
            ascon_round u_round (
                .x0_i      (chain_x0[gi]),
                .x1_i      (chain_x1[gi]),
                .x2_i      (chain_x2[gi]),
                .x3_i      (chain_x3[gi]),
                .x4_i      (chain_x4[gi]),
                .round_idx (eff_idx + gi[3:0]),
                .x0_o      (chain_x0[gi+1]),
                .x1_o      (chain_x1[gi+1]),
                .x2_o      (chain_x2[gi+1]),
                .x3_o      (chain_x3[gi+1]),
                .x4_o      (chain_x4[gi+1])
            );
        end
    endgenerate

    wire [319:0] round_result = {chain_x0[ROUNDS_PER_CYCLE], chain_x1[ROUNDS_PER_CYCLE],
                                  chain_x2[ROUNDS_PER_CYCLE], chain_x3[ROUNDS_PER_CYCLE],
                                  chain_x4[ROUNDS_PER_CYCLE]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= 320'h0;
            round_idx <= 4'h0;
            busy_r    <= 1'b0;
            done_r    <= 1'b0;
        end else begin
            done_r <= 1'b0;
            if (load) begin
                state  <= state_i;
                busy_r <= 1'b0;
            end else if (start) begin
                state <= round_result;
                if (round_start == LAST_ROUND_IDX) begin
                    busy_r <= 1'b0;
                    done_r <= 1'b1;
                end else begin
                    round_idx <= round_start + STEP;
                    busy_r    <= 1'b1;
                end
            end else if (busy_r) begin
                state <= round_result;
                if (round_idx == LAST_ROUND_IDX) begin
                    busy_r <= 1'b0;
                    done_r <= 1'b1;
                end else begin
                    round_idx <= round_idx + STEP;
                end
            end
        end
    end

    assign busy    = busy_r;
    assign done    = done_r;
    assign state_o = state;

endmodule
