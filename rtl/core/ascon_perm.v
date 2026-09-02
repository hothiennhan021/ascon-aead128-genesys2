// Sequential permutation engine: holds the 320-bit Ascon state and
// runs one ascon_round per clock cycle from round_start through
// round 15. state_i/state_o pack {S0,S1,S2,S3,S4}, S0 in the highest
// bits. `load` overwrites the state register without running a round
// (used by ascon_aead_fsm to XOR data/key into the rate/capacity
// words between permutation calls). Asynchronous active-low reset.

module ascon_perm (
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

    wire [63:0] y0, y1, y2, y3, y4;

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
                if (round_start == 4'd15) begin
                    busy_r <= 1'b0;
                    done_r <= 1'b1;
                end else begin
                    round_idx <= round_start + 4'd1;
                    busy_r    <= 1'b1;
                end
            end else if (busy_r) begin
                state <= round_result;
                if (round_idx == 4'd15) begin
                    busy_r <= 1'b0;
                    done_r <= 1'b1;
                end else begin
                    round_idx <= round_idx + 4'd1;
                end
            end
        end
    end

    assign busy    = busy_r;
    assign done    = done_r;
    assign state_o = state;

endmodule
