// UART-to-APB command FSM for the Genesys 2 demo (rtl/demo/). Parses
// the host protocol byte-by-byte off uart_rx.v and drives
// apb_master.v; replies (for reads) go back out through uart_tx.v.
//
// Protocol (little-endian -- LSB byte first, matching the project's
// Ascon little-endian convention used everywhere else):
//   0x01 addr d0 d1 d2 d3   WRITE:  APB write wdata={d3,d2,d1,d0} at
//                           register `addr`. No reply.
//   0x02 addr               READ:   APB read at `addr`, replies with
//                           4 bytes {d0,d1,d2,d3} (LSB first).
//   0x03                    READ_STATUS: APB read at STATUS (0x04),
//                           same 4-byte reply as READ. No addr byte.
// Any other first byte is silently ignored -- the next byte received
// is again interpreted as a fresh opcode (self-resyncing).

module cmd_fsm (
    input  wire        clk,
    input  wire        rst_n,

    // from uart_rx
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,

    // to uart_tx
    output reg  [7:0]  tx_data,
    output reg         tx_start,
    input  wire        tx_done,

    // to apb_master
    output reg         apb_start,
    output reg         apb_we,
    output reg  [7:0]  apb_addr,
    output reg  [31:0] apb_wdata,
    input  wire [31:0] apb_rdata,
    input  wire        apb_done
);

    localparam [7:0] OP_WRITE       = 8'h01;
    localparam [7:0] OP_READ        = 8'h02;
    localparam [7:0] OP_READ_STATUS = 8'h03;
    localparam [7:0] ADDR_STATUS    = 8'h04;

    localparam [2:0] S_IDLE     = 3'd0;
    localparam [2:0] S_ADDR     = 3'd1;
    localparam [2:0] S_DATA     = 3'd2;
    localparam [2:0] S_APB_WAIT = 3'd3;
    localparam [2:0] S_SEND     = 3'd4;
    localparam [2:0] S_SEND_WAIT= 3'd5;

    reg [2:0]  state;
    reg [7:0]  opcode_r;
    reg [31:0] rdata_r;
    reg [1:0]  byte_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            opcode_r  <= 8'h0;
            rdata_r   <= 32'h0;
            byte_cnt  <= 2'd0;
            tx_data   <= 8'h0;
            tx_start  <= 1'b0;
            apb_start <= 1'b0;
            apb_we    <= 1'b0;
            apb_addr  <= 8'h0;
            apb_wdata <= 32'h0;
        end else begin
            tx_start  <= 1'b0; // defaults: single-cycle pulses
            apb_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (rx_valid) begin
                        opcode_r <= rx_data;
                        case (rx_data)
                            OP_WRITE, OP_READ: state <= S_ADDR;
                            OP_READ_STATUS: begin
                                apb_start <= 1'b1;
                                apb_we    <= 1'b0;
                                apb_addr  <= ADDR_STATUS;
                                state     <= S_APB_WAIT;
                            end
                            default: state <= S_IDLE; // unknown opcode: resync
                        endcase
                    end
                end

                S_ADDR: begin
                    if (rx_valid) begin
                        apb_addr <= rx_data;
                        if (opcode_r == OP_WRITE) begin
                            byte_cnt <= 2'd0;
                            state    <= S_DATA;
                        end else begin // OP_READ
                            apb_start <= 1'b1;
                            apb_we    <= 1'b0;
                            state     <= S_APB_WAIT;
                        end
                    end
                end

                S_DATA: begin
                    if (rx_valid) begin
                        // little-endian: byte_cnt 0 is bits [7:0], ...
                        // 3 is bits [31:24]. Safe to also raise
                        // apb_start on the byte_cnt==3 edge: apb_wdata
                        // and apb_start are independent registers, so
                        // both take effect together one cycle later,
                        // by which time apb_wdata already holds all 4
                        // bytes (the first 3 landed on earlier edges).
                        apb_wdata[byte_cnt*8 +: 8] <= rx_data;
                        if (byte_cnt == 2'd3) begin
                            apb_start <= 1'b1;
                            apb_we    <= 1'b1;
                            state     <= S_APB_WAIT;
                        end else begin
                            byte_cnt <= byte_cnt + 2'd1;
                        end
                    end
                end

                S_APB_WAIT: begin
                    if (apb_done) begin
                        if (opcode_r == OP_WRITE) begin
                            state <= S_IDLE;
                        end else begin
                            rdata_r  <= apb_rdata;
                            byte_cnt <= 2'd0;
                            state    <= S_SEND;
                        end
                    end
                end

                S_SEND: begin
                    tx_data  <= rdata_r[byte_cnt*8 +: 8];
                    tx_start <= 1'b1;
                    state    <= S_SEND_WAIT;
                end

                S_SEND_WAIT: begin
                    // poll tx_done (resting 0, pulses once), not
                    // tx_busy -- polling "!tx_busy" here would race
                    // the 1-cycle start->busy latency in uart_tx.v.
                    if (tx_done) begin
                        if (byte_cnt == 2'd3) begin
                            state <= S_IDLE;
                        end else begin
                            byte_cnt <= byte_cnt + 2'd1;
                            state    <= S_SEND;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
