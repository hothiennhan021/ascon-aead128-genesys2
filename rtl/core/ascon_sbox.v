// Ascon-AEAD128 5-bit S-box, bit-sliced across 64 lanes.
// x2_i is expected to already have the round constant XORed in (done
// by the caller, ascon_round). Combinational, no clock/reset.

module ascon_sbox (
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

    reg [63:0] v0, v1, v2, v3, v4;
    reg [63:0] t0, t1, t2, t3, t4;

    always @(*) begin
        v0 = x0_i;
        v1 = x1_i;
        v2 = x2_i;
        v3 = x3_i;
        v4 = x4_i;

        v0 = v0 ^ v4;
        v4 = v4 ^ v3;
        v2 = v2 ^ v1;

        t0 = (~v0) & v1;
        t1 = (~v1) & v2;
        t2 = (~v2) & v3;
        t3 = (~v3) & v4;
        t4 = (~v4) & v0;

        v0 = v0 ^ t1;
        v1 = v1 ^ t2;
        v2 = v2 ^ t3;
        v3 = v3 ^ t4;
        v4 = v4 ^ t0;

        v1 = v1 ^ v0;
        v0 = v0 ^ v4;
        v3 = v3 ^ v2;
        v2 = ~v2;
    end

    assign x0_o = v0;
    assign x1_o = v1;
    assign x2_o = v2;
    assign x3_o = v3;
    assign x4_o = v4;

endmodule
