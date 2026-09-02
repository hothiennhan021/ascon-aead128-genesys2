// Unit testbench for ascon_perm: loads the all-zero state, runs p12
// then p8, and compares state_o after each clock cycle against the
// per-round golden dumps from model/ascon_model.py (--dump-p12 /
// --dump-p8), captured in golden_p12.hex / golden_p8.hex.

`timescale 1ns/1ps

module tb_perm;

    reg clk;
    reg rst_n;
    reg [319:0] state_i;
    reg load;
    reg start;
    reg [3:0] round_start;
    wire busy;
    wire done;
    wire [319:0] state_o;

    ascon_perm dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .state_i     (state_i),
        .load        (load),
        .start       (start),
        .round_start (round_start),
        .busy        (busy),
        .done        (done),
        .state_o     (state_o)
    );

    always #5 clk = ~clk;

    reg [63:0] mem12 [0:64];
    reg [63:0] mem8  [0:44];

    integer i;
    integer errors;
    integer checks;
    reg [319:0] expected;

    task run_perm;
        input [3:0] rstart;
        input integer nrounds;
        begin
            // reset core
            rst_n = 1'b0;
            load  = 1'b0;
            start = 1'b0;
            @(negedge clk);
            @(negedge clk);
            rst_n = 1'b1;

            // load all-zero state
            @(negedge clk);
            state_i = 320'h0;
            load    = 1'b1;
            @(negedge clk);
            load = 1'b0;

            // start permutation
            round_start = rstart;
            start       = 1'b1;
            @(negedge clk);
            start = 1'b0;

            for (i = 1; i <= nrounds; i = i + 1) begin
                if (rstart == 4'd4) begin
                    expected = {mem12[i*5+0], mem12[i*5+1], mem12[i*5+2],
                                mem12[i*5+3], mem12[i*5+4]};
                end else begin
                    expected = {mem8[i*5+0], mem8[i*5+1], mem8[i*5+2],
                                mem8[i*5+3], mem8[i*5+4]};
                end
                checks = checks + 1;
                if (state_o !== expected) begin
                    errors = errors + 1;
                    $display("FAIL perm rstart=%0d round=%0d got=%h exp=%h",
                              rstart, i, state_o, expected);
                end else begin
                    $display("PASS perm rstart=%0d round=%0d", rstart, i);
                end
                if (i == nrounds) begin
                    if (done !== 1'b1) begin
                        errors = errors + 1;
                        $display("FAIL perm rstart=%0d done not asserted on last round", rstart);
                    end
                    if (busy !== 1'b0) begin
                        errors = errors + 1;
                        $display("FAIL perm rstart=%0d busy not deasserted on last round", rstart);
                    end
                end else begin
                    @(negedge clk);
                end
            end
        end
    endtask

    initial begin
        $readmemh("tb/unit/golden_p12.hex", mem12);
        $readmemh("tb/unit/golden_p8.hex", mem8);

        clk    = 1'b0;
        rst_n  = 1'b0;
        state_i = 320'h0;
        load   = 1'b0;
        start  = 1'b0;
        round_start = 4'h0;
        errors = 0;
        checks = 0;

        run_perm(4'd4, 12); // p12
        run_perm(4'd8, 8);  // p8

        if (errors == 0)
            $display("PASS tb_perm: %0d/%0d checks", checks, checks);
        else
            $display("FAIL tb_perm: %0d/%0d checks failed", errors, checks);

        $finish;
    end

endmodule
