// Unit testbench for ascon_linear. Uses an ascon_sbox helper instance
// (separately unit-tested by tb_sbox.v) to produce the DUT's input
// from the golden pre-round state, XORing the round constant into x2
// itself (shared table in ascon_rc_table.vh), and compares the DUT's
// output directly against the same per-round golden dumps used by
// tb_round.v (model/ascon_model.py --dump-p12 / --dump-p8).

`timescale 1ns/1ps

module tb_linear;

    `include "ascon_rc_table.vh"

    reg  [63:0] x0_i, x1_i, x2_i, x3_i, x4_i;
    wire [63:0] s0, s1, s2, s3, s4;

    ascon_sbox u_sbox_helper (
        .x0_i (x0_i),
        .x1_i (x1_i),
        .x2_i (x2_i),
        .x3_i (x3_i),
        .x4_i (x4_i),
        .x0_o (s0),
        .x1_o (s1),
        .x2_o (s2),
        .x3_o (s3),
        .x4_o (s4)
    );

    wire [63:0] x0_o, x1_o, x2_o, x3_o, x4_o;

    ascon_linear dut (
        .x0_i (s0),
        .x1_i (s1),
        .x2_i (s2),
        .x3_i (s3),
        .x4_i (s4),
        .x0_o (x0_o),
        .x1_o (x1_o),
        .x2_o (x2_o),
        .x3_o (x3_o),
        .x4_o (x4_o)
    );

    reg [63:0] mem12 [0:64];
    reg [63:0] mem8  [0:44];

    integer i;
    integer errors;
    integer checks;
    reg [3:0]  round_idx;
    reg [63:0] exp0, exp1, exp2, exp3, exp4;

    initial begin
        $readmemh("tb/unit/golden_p12.hex", mem12);
        $readmemh("tb/unit/golden_p8.hex", mem8);

        errors = 0;
        checks = 0;

        for (i = 0; i < 12; i = i + 1) begin
            round_idx = 4 + i;
            x0_i = mem12[i*5+0];
            x1_i = mem12[i*5+1];
            x2_i = mem12[i*5+2] ^ {56'h0, tb_rc(round_idx)};
            x3_i = mem12[i*5+3];
            x4_i = mem12[i*5+4];
            #1;
            exp0 = mem12[(i+1)*5+0];
            exp1 = mem12[(i+1)*5+1];
            exp2 = mem12[(i+1)*5+2];
            exp3 = mem12[(i+1)*5+3];
            exp4 = mem12[(i+1)*5+4];
            checks = checks + 1;
            if (x0_o !== exp0 || x1_o !== exp1 || x2_o !== exp2 ||
                x3_o !== exp3 || x4_o !== exp4) begin
                errors = errors + 1;
                $display("FAIL p12 round_idx=%0d got=%016h_%016h_%016h_%016h_%016h exp=%016h_%016h_%016h_%016h_%016h",
                          round_idx, x0_o, x1_o, x2_o, x3_o, x4_o, exp0, exp1, exp2, exp3, exp4);
            end else begin
                $display("PASS p12 round_idx=%0d", round_idx);
            end
        end

        for (i = 0; i < 8; i = i + 1) begin
            round_idx = 8 + i;
            x0_i = mem8[i*5+0];
            x1_i = mem8[i*5+1];
            x2_i = mem8[i*5+2] ^ {56'h0, tb_rc(round_idx)};
            x3_i = mem8[i*5+3];
            x4_i = mem8[i*5+4];
            #1;
            exp0 = mem8[(i+1)*5+0];
            exp1 = mem8[(i+1)*5+1];
            exp2 = mem8[(i+1)*5+2];
            exp3 = mem8[(i+1)*5+3];
            exp4 = mem8[(i+1)*5+4];
            checks = checks + 1;
            if (x0_o !== exp0 || x1_o !== exp1 || x2_o !== exp2 ||
                x3_o !== exp3 || x4_o !== exp4) begin
                errors = errors + 1;
                $display("FAIL p8 round_idx=%0d got=%016h_%016h_%016h_%016h_%016h exp=%016h_%016h_%016h_%016h_%016h",
                          round_idx, x0_o, x1_o, x2_o, x3_o, x4_o, exp0, exp1, exp2, exp3, exp4);
            end else begin
                $display("PASS p8 round_idx=%0d", round_idx);
            end
        end

        if (errors == 0)
            $display("PASS tb_linear: %0d/%0d checks", checks, checks);
        else
            $display("FAIL tb_linear: %0d/%0d checks failed", errors, checks);

        $finish;
    end

endmodule
