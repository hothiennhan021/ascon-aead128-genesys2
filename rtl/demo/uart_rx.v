// UART receiver, 8N1, no flow control. Part of the Genesys 2 demo
// (rtl/demo/) -- does not depend on rtl/core/ or rtl/ip/.
//
// CLK_FREQ_HZ/BAUD select the bit period in clk cycles. Default
// 100_000_000 / 115200 matches top_board.v's post-MMCM clock and the
// protocol baud rate the task asked for; both are plain parameters so
// tb/directed/tb_top_board.v can pick faster values to keep
// simulation time short without changing this file.
//
// `rx` is asynchronous to `clk` (comes straight off a board pin) --
// double-flopped before use. Start bit is re-checked at mid-bit to
// reject glitches; `valid` pulses for exactly one cycle when a byte
// completes.

module uart_rx #(
    parameter CLK_FREQ_HZ = 100_000_000,
    parameter BAUD        = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid
);

    localparam integer CYCLES_PER_BIT = CLK_FREQ_HZ / BAUD;

    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_START = 2'd1;
    localparam [1:0] S_DATA  = 2'd2;
    localparam [1:0] S_STOP  = 2'd3;

    reg        rx_sync0, rx_sync1;
    reg [1:0]  state;
    reg [15:0] cycle_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  shift_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync0 <= 1'b1;
            rx_sync1 <= 1'b1;
        end else begin
            rx_sync0 <= rx;
            rx_sync1 <= rx_sync0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            cycle_cnt <= 16'd0;
            bit_idx   <= 3'd0;
            shift_reg <= 8'h0;
            data      <= 8'h0;
            valid     <= 1'b0;
        end else begin
            valid <= 1'b0; // default: single-cycle pulse

            case (state)
                S_IDLE: begin
                    if (!rx_sync1) begin // falling edge -> candidate start bit
                        cycle_cnt <= 16'd0;
                        state     <= S_START;
                    end
                end

                S_START: begin
                    if (cycle_cnt == (CYCLES_PER_BIT/2)) begin
                        if (!rx_sync1) begin // still low at mid-bit: real start bit
                            cycle_cnt <= 16'd0;
                            bit_idx   <= 3'd0;
                            state     <= S_DATA;
                        end else begin
                            state <= S_IDLE; // glitch, not a real start bit
                        end
                    end else begin
                        cycle_cnt <= cycle_cnt + 16'd1;
                    end
                end

                S_DATA: begin
                    if (cycle_cnt == CYCLES_PER_BIT-1) begin
                        cycle_cnt <= 16'd0;
                        shift_reg <= {rx_sync1, shift_reg[7:1]}; // LSB first
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
                    if (cycle_cnt == CYCLES_PER_BIT-1) begin
                        cycle_cnt <= 16'd0;
                        data      <= shift_reg;
                        valid     <= 1'b1;
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
