// UART transmitter, 8N1, no flow control. Part of the Genesys 2 demo
// (rtl/demo/) -- does not depend on rtl/core/ or rtl/ip/.
//
// CLK_FREQ_HZ/BAUD mirror uart_rx.v -- see that file's header.
//
// `busy` is high from the cycle `start` is accepted until the stop
// bit finishes; `done` pulses for exactly one cycle at that same
// moment. cmd_fsm.v polls `done` (not `busy`) to sequence multi-byte
// replies -- `done`'s resting value is 0 and it only ever pulses once
// per byte, so there is no race against the 1-cycle start->busy
// latency the way there would be polling "busy deasserted" right
// after asserting `start` (busy has not risen yet on that first
// cycle).
module uart_tx #(
    parameter CLK_FREQ_HZ = 100_000_000,
    parameter BAUD        = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       start,
    output reg        tx,
    output reg        busy,
    output reg        done
);

    localparam integer CYCLES_PER_BIT = CLK_FREQ_HZ / BAUD;

    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_START = 2'd1;
    localparam [1:0] S_DATA  = 2'd2;
    localparam [1:0] S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [15:0] cycle_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  shift_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            cycle_cnt <= 16'd0;
            bit_idx   <= 3'd0;
            shift_reg <= 8'h0;
            tx        <= 1'b1; // idle line is high
            busy      <= 1'b0;
            done      <= 1'b0;
        end else begin
            done <= 1'b0; // default: single-cycle pulse

            case (state)
                S_IDLE: begin
                    tx <= 1'b1;
                    if (start) begin
                        shift_reg <= data;
                        busy      <= 1'b1;
                        cycle_cnt <= 16'd0;
                        state     <= S_START;
                    end else begin
                        busy <= 1'b0;
                    end
                end

                S_START: begin
                    tx <= 1'b0; // start bit
                    if (cycle_cnt == CYCLES_PER_BIT-1) begin
                        cycle_cnt <= 16'd0;
                        bit_idx   <= 3'd0;
                        state     <= S_DATA;
                    end else begin
                        cycle_cnt <= cycle_cnt + 16'd1;
                    end
                end

                S_DATA: begin
                    tx <= shift_reg[0];
                    if (cycle_cnt == CYCLES_PER_BIT-1) begin
                        cycle_cnt <= 16'd0;
                        shift_reg <= {1'b0, shift_reg[7:1]};
                        if (bit_idx == 3'd7) begin
                            state <= S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 3'd1;
                        end
                    end else begin
                        cycle_cnt <= cycle_cnt + 16'd1;
                    end
                end

                S_STOP: begin
                    tx <= 1'b1; // stop bit
                    if (cycle_cnt == CYCLES_PER_BIT-1) begin
                        cycle_cnt <= 16'd0;
                        busy      <= 1'b0;
                        done      <= 1'b1;
                        state     <= S_IDLE;
                    end else begin
                        cycle_cnt <= cycle_cnt + 16'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
