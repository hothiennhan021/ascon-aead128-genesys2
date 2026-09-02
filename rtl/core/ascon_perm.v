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
// bit-for-bit unchanged. ROUNDS_PER_CYCLE=2 instantiates ascon_round
// twice in series: the first takes the current round_idx, the second
// takes round_idx+1, and the counter steps by 2 each cycle. p12 (12
// rounds, start index 4) then runs 6 cycles (index 4,6,8,10,12,14)
// and p8 (8 rounds, start index 8) runs 4 cycles (index 8,10,12,14) —
// both counts are even, so no odd-round remainder handling is needed
// (see docs/uarch.md section 6).
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
    // ROUNDS_PER_CYCLE=1, 14 for ROUNDS_PER_CYCLE=2 (round pair
    // (14,15) is the final one) -- 4'd15 - (STEP-1).
    localparam [3:0] STEP          = ROUNDS_PER_CYCLE[3:0];
    localparam [3:0] LAST_ROUND_IDX = 4'd15 - (STEP - 4'd1);

    wire [63:0] y0, y1, y2, y3, y4;

    generate
        if (ROUNDS_PER_CYCLE == 1) begin : g_single_round
            ascon_round u_round (
                .x0_i      (cur_x0),
                .x1_i      (cur_x1),
                .x2_i      (cur_x2),
                .x3_i      (cur_x3),
                .x4_i      (cur_x4),
                .round_idx (eff_idx),
                .x0_o      (y0),
                .x1_o      (y1),
                .x2_o      (y2),
                .x3_o      (y3),
                .x4_o      (y4)
            );
        end else begin : g_double_round
            wire [63:0] m0, m1, m2, m3, m4;

            ascon_round u_round0 (
                .x0_i      (cur_x0),
                .x1_i      (cur_x1),
                .x2_i      (cur_x2),
                .x3_i      (cur_x3),
                .x4_i      (cur_x4),
                .round_idx (eff_idx),
                .x0_o      (m0),
                .x1_o      (m1),
                .x2_o      (m2),
                .x3_o      (m3),
                .x4_o      (m4)
            );

            ascon_round u_round1 (
                .x0_i      (m0),
                .x1_i      (m1),
                .x2_i      (m2),
                .x3_i      (m3),
                .x4_i      (m4),
                .round_idx (eff_idx + 4'd1),
                .x0_o      (y0),
                .x1_o      (y1),
                .x2_o      (y2),
                .x3_o      (y3),
                .x4_o      (y4)
            );
        end
    endgenerate

    wire [319:0] round_result = {y0, y1, y2, y3, y4};

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
