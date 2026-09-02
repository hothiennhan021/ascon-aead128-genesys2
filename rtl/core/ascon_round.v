// One full Ascon-AEAD128 round: round-constant XOR (into x2) + S-box +
// linear layer. round_idx selects the constant via a case statement
// (not a memory array) so synthesis does not infer Block RAM.
// Combinational, no clock/reset.

module ascon_round (
    input  wire [63:0] x0_i,
    input  wire [63:0] x1_i,
    input  wire [63:0] x2_i,
    input  wire [63:0] x3_i,
    input  wire [63:0] x4_i,
    input  wire [3:0]  round_idx,
    output wire [63:0] x0_o,
    output wire [63:0] x1_o,
    output wire [63:0] x2_o,
    output wire [63:0] x3_o,
    output wire [63:0] x4_o
);

    reg [7:0] rc;

    always @(*) begin
        rc = 8'h00;
        case (round_idx)
            4'd0:  rc = 8'h3c;
            4'd1:  rc = 8'h2d;
            4'd2:  rc = 8'h1e;
            4'd3:  rc = 8'h0f;
            4'd4:  rc = 8'hf0;
            4'd5:  rc = 8'he1;
            4'd6:  rc = 8'hd2;
            4'd7:  rc = 8'hc3;
            4'd8:  rc = 8'hb4;
            4'd9:  rc = 8'ha5;
            4'd10: rc = 8'h96;
            4'd11: rc = 8'h87;
            4'd12: rc = 8'h78;
            4'd13: rc = 8'h69;
            4'd14: rc = 8'h5a;
            4'd15: rc = 8'h4b;
            default: rc = 8'h00;
        endcase
    end

    wire [63:0] x2_rc;
    assign x2_rc = x2_i ^ {56'h0, rc};

    wire [63:0] s0, s1, s2, s3, s4;

    ascon_sbox u_sbox (
        .x0_i (x0_i),
        .x1_i (x1_i),
        .x2_i (x2_rc),
        .x3_i (x3_i),
        .x4_i (x4_i),
        .x0_o (s0),
        .x1_o (s1),
        .x2_o (s2),
        .x3_o (s3),
        .x4_o (s4)
    );

    ascon_linear u_linear (
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

endmodule
