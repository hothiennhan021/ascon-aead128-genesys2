// Ascon-AEAD128 linear diffusion layer: rotate-right + XOR per word.
// Combinational, no clock/reset.

module ascon_linear (
    input  wire [63:0] x0_i,
    input  wire [63:0] x1_i,
    input  wire [63:0] x2_i,
    input  wire [63:0] x3_i,
    input  wire [63:0] x4_i,
    output wire [63:0] x0_o,
    output wire [63:0] x1_o,
    output wire [63:0] x2_o,
    output wire [63:0] x3_o,
    output wire [63:0] x4_o
);

    function [63:0] rotr;
        input [63:0] x;
        input [5:0]  n;
        begin
            rotr = (x >> n) | (x << (64 - n));
        end
    endfunction

    assign x0_o = x0_i ^ rotr(x0_i, 19) ^ rotr(x0_i, 28);
    assign x1_o = x1_i ^ rotr(x1_i, 61) ^ rotr(x1_i, 39);
    assign x2_o = x2_i ^ rotr(x2_i, 1)  ^ rotr(x2_i, 6);
    assign x3_o = x3_i ^ rotr(x3_i, 10) ^ rotr(x3_i, 17);
    assign x4_o = x4_i ^ rotr(x4_i, 7)  ^ rotr(x4_i, 41);

endmodule
