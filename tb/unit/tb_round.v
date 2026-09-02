// Unit testbench for ascon_round: compares each round's combinational
// output against the per-round golden state dumped by
// model/ascon_model.py (--dump-p12 / --dump-p8), captured statically
// in golden_p12.hex / golden_p8.hex (row 0 = all-zero start state,
// row i = state after round i). Pure combinational DUT, no clock.

`timescale 1ns/1ps

module tb_round;

    reg  [63:0] x0_i, x1_i, x2_i, x3_i, x4_i;
    reg  [3:0]  round_idx;
    wire [63:0] x0_o, x1_o, x2_o, x3_o, x4_o;

    ascon_round dut (
        .x0_i      (x0_i),
        .x1_i      (x1_i),
        .x2_i      (x2_i),
        .x3_i      (x3_i),
        .x4_i      (x4_i),
        .round_idx (round_idx),
        .x0_o      (x0_o),
        .x1_o      (x1_o),
        .x2_o      (x2_o),
        .x3_o      (x3_o),
        .x4_o      (x4_o)
    );

    reg [63:0] mem12 [0:64];
    reg [63:0] mem8  [0:44];

    integer i;
    integer errors;
    integer checks;
    reg [63:0] exp0, exp1, exp2, exp3, exp4;

    initial begin
        $readmemh("tb/unit/golden_p12.hex", mem12);
        $readmemh("tb/unit/golden_p8.hex", mem8);

        errors = 0;
        checks = 0;

        // p12: rows 0..12 golden states, round_idx runs 4..15
        for (i = 0; i < 12; i = i + 1) begin
            x0_i = mem12[i*5+0];
            x1_i = mem12[i*5+1];
            x2_i = mem12[i*5+2];
            x3_i = mem12[i*5+3];
            x4_i = mem12[i*5+4];
            round_idx = 4 + i;
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
                          round_idx, x0_o, x1_o, x2_o, x3_o, x4_o,
                          exp0, exp1, exp2, exp3, exp4);
            end else begin
                $display("PASS p12 round_idx=%0d", round_idx);
            end
        end

        // p8: rows 0..8 golden states, round_idx runs 8..15
        for (i = 0; i < 8; i = i + 1) begin
            x0_i = mem8[i*5+0];
            x1_i = mem8[i*5+1];
            x2_i = mem8[i*5+2];
            x3_i = mem8[i*5+3];
            x4_i = mem8[i*5+4];
            round_idx = 8 + i;
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
                          round_idx, x0_o, x1_o, x2_o, x3_o, x4_o,
                          exp0, exp1, exp2, exp3, exp4);
            end else begin
                $display("PASS p8 round_idx=%0d", round_idx);
            end
        end

        if (errors == 0)
            $display("PASS tb_round: %0d/%0d checks", checks, checks);
        else
            $display("FAIL tb_round: %0d/%0d checks failed", errors, checks);

        $finish;
    end

endmodule
